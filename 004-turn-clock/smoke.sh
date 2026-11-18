#!/usr/bin/env bash
# End-to-end smoke: create a duel, move, resend a move, watch a clock expire,
# replay the log and resign. Any assertion failure fails the run.
set -euo pipefail
cd "$(dirname "$0")"

ARCOD="${ARCOD:-arcod}"
PORT="${PORT:-8097}"
BASE="http://localhost:${PORT}"
LOG="${LOG:-/tmp/arcod-turn-clock.log}"

cleanup() {
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
post() { curl -fsS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
get() { curl -fsS "$BASE$1"; }
field() { jq -r "$1"; }

say "build"
"$ARCOD" build --impl >/dev/null

say "start :${PORT}"
"$ARCOD" run --impl --port "$PORT" >"$LOG" 2>&1 &
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null

# --- a normal duel, three seconds per move ---------------------------------
CREATED=$(post /v1/rooms '{"name":"duel","player":"alice","turnSeconds":3,"bankSeconds":30}')
ROOM=$(echo "$CREATED" | field .room.id)
CODE=$(echo "$CREATED" | field .room.code)
ALICE=$(echo "$CREATED" | field .token)
[ -n "$ROOM" ]
[ "$(echo "$CREATED" | field .room.status)" = "waiting" ]
[ "$(echo "$CREATED" | field .room.board)" = "........." ]
say "room $ROOM ($CODE) created by alice"

JOINED=$(post "/v1/rooms/$ROOM/join" "{\"code\":\"$CODE\",\"name\":\"bob\"}")
BOB=$(echo "$JOINED" | field .token)
[ "$(echo "$JOINED" | field .role)" = "p2" ]

STATE=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$ALICE\",\"kind\":\"sync\"}")
[ "$(echo "$STATE" | field .room.status)" = "active" ]
[ "$(echo "$STATE" | field .room.turn)" = "p1" ]
[ "$(echo "$STATE" | field .room.seq)" = "1" ]
say "bob joined, alice moves first"

M1=00000000-0000-4000-8000-000000000201
M2=00000000-0000-4000-8000-000000000202
M3=00000000-0000-4000-8000-000000000203

MOVED=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$ALICE\",\"kind\":\"move\",\"cell\":4,\"moveId\":\"$M1\"}")
[ "$(echo "$MOVED" | field .accepted)" = "true" ]
[ "$(echo "$MOVED" | field .duplicate)" = "false" ]
[ "$(echo "$MOVED" | field .room.board)" = "....x...." ]
[ "$(echo "$MOVED" | field .room.turn)" = "p2" ]
SEQ1=$(echo "$MOVED" | field .seq)
say "alice played the centre, seq $SEQ1"

# The same move id twice must not place a second mark nor bill a second think.
AGAIN=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$ALICE\",\"kind\":\"move\",\"cell\":2,\"moveId\":\"$M1\"}")
[ "$(echo "$AGAIN" | field .duplicate)" = "true" ]
[ "$(echo "$AGAIN" | field .room.board)" = "....x...." ]
[ "$(echo "$AGAIN" | field .seq)" = "$SEQ1" ]
say "resending move $M1 is idempotent"

MOVED2=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$BOB\",\"kind\":\"move\",\"cell\":0,\"moveId\":\"$M2\"}")
[ "$(echo "$MOVED2" | field .accepted)" = "true" ]
[ "$(echo "$MOVED2" | field .room.board)" = "o...x...." ]
say "bob answered in the corner"

TWICE=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$BOB\",\"kind\":\"move\",\"cell\":1,\"moveId\":\"$M3\"}")
[ "$(echo "$TWICE" | field .accepted)" = "false" ]
[ "$(echo "$TWICE" | field .note)" = "out-of-turn" ]
say "a move out of turn is refused without an error status"

TAKEN=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$ALICE\",\"kind\":\"move\",\"cell\":0,\"moveId\":\"$M3\"}")
[ "$(echo "$TAKEN" | field .accepted)" = "false" ]
[ "$(echo "$TAKEN" | field .note)" = "cell-taken" ]
say "a taken cell is refused"

MOVED3=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$ALICE\",\"kind\":\"move\",\"cell\":8,\"moveId\":\"$M3\"}")
[ "$(echo "$MOVED3" | field .accepted)" = "true" ]
[ "$(echo "$MOVED3" | field .room.board)" = "o...x...x" ]
[ "$(echo "$MOVED3" | field .room.turn)" = "p2" ]
say "alice crossed a diagonal"

# --- the event log is a delta, and the replay recomputes the same board -----
DELTA=$(get "/v1/rooms/$ROOM/events?after=3")
[ "$(echo "$DELTA" | jq 'length')" = "1" ]
[ "$(echo "$DELTA" | field '.[0].seq')" = "4" ]
[ "$(echo "$DELTA" | field '.[0].kind')" = "move" ]
say "events after seq 3 is exactly one move"

REPLAY=$(get "/v1/rooms/$ROOM/replay")
[ "$(echo "$REPLAY" | field .consistent)" = "true" ]
[ "$(echo "$REPLAY" | field .moves)" = "3" ]
[ "$(echo "$REPLAY" | field .board)" = "o...x...x" ]
say "replay folds the log back into the same board"

# --- websocket: a waiter sees the resignation as it happens -----------------
ROOM="$ROOM" BASE="$BASE" TOKEN="$BOB" node - <<'NODE'
const { ROOM, BASE, TOKEN } = process.env;
const ws = new WebSocket(BASE.replace('http', 'ws') + '/ws?topic=room:' + ROOM);
const timer = setTimeout(() => { console.log('websocket timeout'); process.exit(1); }, 8000);
ws.onopen = async () => {
  await fetch(BASE + '/v1/rooms/' + ROOM + '/tick', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ token: TOKEN, kind: 'resign' }),
  });
};
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'tick' && msg.kind === 'resign') {
    clearTimeout(timer);
    console.log('websocket broadcast', msg.seq);
    ws.close();
    process.exit(0);
  }
};
ws.onerror = () => { console.log('websocket error'); process.exit(1); };
NODE
say "bob resigned, the stream carried it"

FINAL=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$ALICE\",\"kind\":\"sync\"}")
[ "$(echo "$FINAL" | field .room.status)" = "finished" ]
[ "$(echo "$FINAL" | field .room.winner)" = "p1" ]
[ "$(echo "$FINAL" | field .room.reason)" = "resign" ]

LATE=$(post "/v1/rooms/$ROOM/tick" "{\"token\":\"$BOB\",\"kind\":\"move\",\"cell\":1,\"moveId\":\"00000000-0000-4000-8000-000000000204\"}")
[ "$(echo "$LATE" | field .accepted)" = "false" ]
[ "$(echo "$LATE" | field .note)" = "finished" ]
say "a finished room refuses moves"

SPECT=$(post "/v1/rooms/$ROOM/join" "{\"code\":\"$CODE\",\"name\":\"carol\"}")
[ "$(echo "$SPECT" | field .role)" = "spectator" ]
[ -n "$(echo "$SPECT" | field .token)" ]
say "a late caller joins as a spectator"

# --- two moves for one turn at once: exactly one lands ----------------------
RACE=$(post /v1/rooms '{"name":"race","player":"frank","turnSeconds":10,"bankSeconds":30}')
RACE_ID=$(echo "$RACE" | field .room.id)
RACE_CODE=$(echo "$RACE" | field .room.code)
FRANK=$(echo "$RACE" | field .token)
post "/v1/rooms/$RACE_ID/join" "{\"code\":\"$RACE_CODE\",\"name\":\"gina\"}" >/dev/null

post "/v1/rooms/$RACE_ID/tick" "{\"token\":\"$FRANK\",\"kind\":\"move\",\"cell\":0,\"moveId\":\"00000000-0000-4000-8000-000000000205\"}" >/tmp/arcod-race-a.json &
PA=$!
post "/v1/rooms/$RACE_ID/tick" "{\"token\":\"$FRANK\",\"kind\":\"move\",\"cell\":1,\"moveId\":\"00000000-0000-4000-8000-000000000206\"}" >/tmp/arcod-race-b.json &
PB=$!
wait "$PA" || true
wait "$PB" || true
LANDED=$(cat /tmp/arcod-race-a.json /tmp/arcod-race-b.json | jq -s '[.[] | select(.accepted == true)] | length')
[ "$LANDED" = "1" ]
RACE_VIEW=$(post "/v1/rooms/$RACE_ID/tick" "{\"token\":\"$FRANK\",\"kind\":\"sync\"}")
[ "$(echo "$RACE_VIEW" | field .room.seq)" = "2" ]
[ "$(echo "$RACE_VIEW" | field .room.board | tr -cd 'x' | wc -c | tr -d ' ')" = "1" ]
say "two simultaneous moves: one accepted, one out of turn"

# --- clocks: a bank of four seconds, two per move, nobody touches the board --
SLOW=$(post /v1/rooms '{"name":"forfeit","player":"dave","turnSeconds":2,"bankSeconds":4}')
SLOW_ID=$(echo "$SLOW" | field .room.id)
SLOW_CODE=$(echo "$SLOW" | field .room.code)
DAVE=$(echo "$SLOW" | field .token)
post "/v1/rooms/$SLOW_ID/join" "{\"code\":\"$SLOW_CODE\",\"name\":\"erin\"}" >/dev/null

sleep 2.8
TICK1=$(post "/v1/rooms/$SLOW_ID/tick" "{\"kind\":\"sync\"}")
[ "$(echo "$TICK1" | field .timeouts)" -ge 1 ]
[ "$(echo "$TICK1" | field .room.status)" = "active" ]
say "first expired clock moved the turn"

sleep 4.2
TICK2=$(post "/v1/rooms/$SLOW_ID/tick" "{\"kind\":\"sync\"}")
[ "$(echo "$TICK2" | field .room.status)" = "finished" ]
[ "$(echo "$TICK2" | field .room.reason)" = "timeout" ]
[ "$(echo "$TICK2" | field .timeouts)" -ge 2 ]
[ "$(echo "$TICK2" | field .room.winner)" = "p2" ]
say "an exhausted bank forfeits the game to the other player"

TIMEOUTS=$(get "/v1/rooms/$SLOW_ID/events" | jq '[.[] | select(.kind == "timeout")] | length')
[ "$TIMEOUTS" -ge 3 ]
say "$TIMEOUTS timeouts in the log, none of them written by a client"

say "PASS"
