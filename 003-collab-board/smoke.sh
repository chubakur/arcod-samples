#!/usr/bin/env bash
# End-to-end smoke: build, start the stack, merge concurrent edits, read the
# board and watch a websocket broadcast. Any assertion failure fails the run.
set -euo pipefail
cd "$(dirname "$0")"

ARCOD="${ARCOD:-arcod}"
PORT="${PORT:-8096}"
BASE="http://localhost:${PORT}"
LOG="${LOG:-/tmp/arcod-collab-board.log}"

cleanup() {
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

say "build"
"$ARCOD" build --impl >/dev/null

say "start :${PORT}"
"$ARCOD" run --impl --port "$PORT" >"$LOG" 2>&1 &
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" | jq -e '.service == "CollabBoard"' >/dev/null
say "health ok"

ROOM_JSON=$(curl -fsS -X POST "$BASE/v1/rooms" -H 'content-type: application/json' \
  -d '{"name":"sprint 42"}')
ROOM=$(echo "$ROOM_JSON" | jq -r .id)
[ -n "$ROOM" ]
[ "$(curl -fsS "$BASE/v1/rooms/$ROOM/board" | jq -r .revision)" = "0" ]
say "room $ROOM created, revision 0"

S1=00000000-0000-4000-8000-000000000001
S2=00000000-0000-4000-8000-000000000002

op() {
  curl -fsS -X POST "$BASE/v1/rooms/$ROOM/ops" -H 'content-type: application/json' -d "$1"
}

# 1. A rectangle appears.
op "{\"opId\":\"00000000-0000-4000-8000-000000000101\",\"clientId\":\"alice\",\"shapeId\":\"$S1\",\"kind\":\"add\",\"lamport\":1,\"x\":10,\"y\":20,\"w\":100,\"h\":50,\"color\":\"#ff0000\"}" >/dev/null

# 2-3. Two clients edit different fields at the same Lamport clock: both survive.
op "{\"opId\":\"00000000-0000-4000-8000-000000000102\",\"clientId\":\"alice\",\"shapeId\":\"$S1\",\"kind\":\"update\",\"lamport\":2,\"x\":30}" >/dev/null
op "{\"opId\":\"00000000-0000-4000-8000-000000000103\",\"clientId\":\"zoe\",\"shapeId\":\"$S1\",\"kind\":\"update\",\"lamport\":2,\"y\":40}" >/dev/null

# 4-5. Same field, same clock: client id breaks the tie deterministically.
op "{\"opId\":\"00000000-0000-4000-8000-000000000104\",\"clientId\":\"alice\",\"shapeId\":\"$S1\",\"kind\":\"update\",\"lamport\":3,\"color\":\"red\"}" >/dev/null
op "{\"opId\":\"00000000-0000-4000-8000-000000000105\",\"clientId\":\"zoe\",\"shapeId\":\"$S1\",\"kind\":\"update\",\"lamport\":3,\"color\":\"blue\"}" >/dev/null

# 6. An old edit loses without corrupting the newer values.
op "{\"opId\":\"00000000-0000-4000-8000-000000000106\",\"clientId\":\"bob\",\"shapeId\":\"$S1\",\"kind\":\"update\",\"lamport\":1,\"x\":99}" >/dev/null

curl -fsS "$BASE/v1/rooms/$ROOM/board" \
  | jq -e '.shapes[0] | .x == 30 and .y == 40 and .color == "blue" and .colorBy == "zoe"' >/dev/null
say "concurrent edits merged: x=30, y=40, color=blue"

REPEAT=$(op "{\"opId\":\"00000000-0000-4000-8000-000000000101\",\"clientId\":\"alice\",\"shapeId\":\"$S1\",\"kind\":\"add\",\"lamport\":1,\"x\":10,\"y\":20,\"w\":100,\"h\":50,\"color\":\"#ff0000\"}")
[ "$(echo "$REPEAT" | jq -r .duplicate)" = "true" ]
[ "$(echo "$REPEAT" | jq -r .revision)" = "6" ]
say "duplicate operation id is idempotent"

# 7. A second client subscribes and sees the next operation over websocket.
ROOM="$ROOM" BASE="$BASE" S2="$S2" node - <<'NODE'
const { ROOM, BASE, S2 } = process.env;
const ws = new WebSocket(BASE.replace('http', 'ws') + '/ws?topic=room:' + ROOM);
const timer = setTimeout(() => { console.log('websocket timeout'); process.exit(1); }, 8000);
ws.onopen = async () => {
  const res = await fetch(BASE + '/v1/rooms/' + ROOM + '/ops', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      opId: '00000000-0000-4000-8000-000000000107',
      clientId: 'alice', shapeId: S2, kind: 'add', lamport: 4,
      x: 5, y: 6, w: 20, h: 10, color: 'green',
    }),
  });
  if (!res.ok) { console.log('post failed', res.status); process.exit(1); }
};
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'op' && msg.op.shapeId === S2) {
    clearTimeout(timer);
    console.log('websocket broadcast', msg.revision);
    ws.close();
    process.exit(0);
  }
};
ws.onerror = () => { console.log('websocket error'); process.exit(1); };
NODE
say "websocket delivered the new shape"

# 8. Delete is a tombstone: the shape disappears from the board, the op stays.
op "{\"opId\":\"00000000-0000-4000-8000-000000000108\",\"clientId\":\"alice\",\"shapeId\":\"$S1\",\"kind\":\"delete\",\"lamport\":5}" >/dev/null
curl -fsS "$BASE/v1/rooms/$ROOM/board" \
  | jq -e '.revision == 8 and (.shapes | length) == 1 and .shapes[0].id == "'"$S2"'"' >/dev/null
say "tombstone removed the first shape, revision 8"

# Catch-up from the log: seq 7 and 8.
[ "$(curl -fsS "$BASE/v1/rooms/$ROOM/ops?after=6" | jq 'length')" = "2" ]
[ "$(curl -fsS "$BASE/v1/rooms/$ROOM/ops" | jq 'length')" = "8" ]
say "operation log catch-up after=6 returns 2 ops"

# Declared errors, not 500s.
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/rooms/00000000-0000-4000-8000-000000000999/board")" = "404" ]
[ "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/rooms/$ROOM/ops" \
  -H 'content-type: application/json' \
  -d '{"opId":"00000000-0000-4000-8000-000000000109","clientId":"bob","shapeId":"00000000-0000-4000-8000-000000000999","kind":"delete","lamport":6}')" = "400" ]
[ "$(curl -fsS "$BASE/v1/rooms" | jq 'length')" -ge 1 ]
say "errors: unknown room 404, unknown shape 400"

say "sample 003: PASS"
