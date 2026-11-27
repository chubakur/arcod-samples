#!/usr/bin/env bash
# 046-matchmaking-arena: 2v2 queue, rating-window matchmaking, ready-check,
# Elo settlement, S3 result archive. Four providers: mysql, redis (queue),
# minio (blob), websocket (stream). Two queue consumers: matchmake and archive.
# Checks: validation 400/404, one waiting ticket per player (409), match formed
# by the consumer with balanced teams, ready-check state machine, live
# websocket event, zero-sum Elo, result idempotency 409, archive in S3, sweep
# timeout requeues everyone, no dead letters.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8098}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-046.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:--}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  [ -n "${WS_PID:-}" ] && kill "$WS_PID" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

say "check"
$ARCOD check >/dev/null

say "build"
$ARCOD build --impl --port "$PORT" >/dev/null

say "run"
$ARCOD run --impl --port "$PORT" >"$LOG" 2>&1 &
RUN_PID=$!
for _ in $(seq 1 120); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -40 "$LOG"; fail "service did not start"; }

post() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
code() { curl -sS -o /tmp/arcod-046-body.json -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }

say "players: create, profile, leaderboard, invalid"
for i in 1 2 3 4; do
  ID=$(post /v1/players "{\"name\":\"P$i\",\"rating\":$((1150 + i * 50))}" | J .id)
  [ -n "$ID" ] && [ "$ID" != null ] || fail "player $i was not created"
  eval "P$i=$ID"
done
[ "$(curl -sS "$BASE/v1/players/$P1" | J .name)" = "P1" ] || fail "profile lost the name"
[ "$(curl -sS "$BASE/v1/leaderboard?limit=2" | jq length)" = "2" ] || fail "leaderboard limit ignored"
[ "$(code /v1/players '{"name":"Bad","rating":5000}')" = "400" ] || fail "rating above 4000 should be 400"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/players/nope")" = "404" ] || fail "unknown player should be 404"

say "queue: four solo players"
for p in "$P1" "$P2" "$P3" "$P4"; do
  [ "$(code /v1/queue "{\"playerId\":\"$p\"}")" = "201" ] || fail "enqueue rejected $p"
done
[ "$(code /v1/queue "{\"playerId\":\"$P1\"}")" = "409" ] || fail "duplicate ticket should be 409"

say "matchmaking: consumer forms a balanced match"
MATCH=""
for _ in $(seq 1 60); do
  TICKET=$(curl -sS "$BASE/v1/queue/$P1")
  STATUS=$(printf '%s' "$TICKET" | J .status)
  MATCH=$(printf '%s' "$TICKET" | J .matchId)
  [ "$STATUS" = "matched" ] && [ -n "$MATCH" ] && [ "$MATCH" != null ] && break
  sleep 0.5
done
[ -n "$MATCH" ] && [ "$MATCH" != null ] || fail "consumer did not form a match"
VIEW=$(curl -sS "$BASE/v1/matches/$MATCH")
[ "$(printf '%s' "$VIEW" | J .match.status)" = "ready" ] || fail "new match is not ready"
[ "$(printf '%s' "$VIEW" | jq '.members | length')" = "4" ] || fail "match does not have four members"
A=$(printf '%s' "$VIEW" | J .match.ratingA)
B=$(printf '%s' "$VIEW" | J .match.ratingB)
[ $((A > B ? A - B : B - A)) -le 50 ] || fail "teams are not balanced: $A vs $B"

say "ready-check: three of four keeps the lobby open"
for p in "$P1" "$P2" "$P3"; do
  [ "$(code "/v1/matches/$MATCH/ready" "{\"playerId\":\"$p\"}")" = "201" ] || fail "ready rejected"
done
[ "$(curl -sS "$BASE/v1/matches/$MATCH" | J .match.status)" = "ready" ] || fail "lobby went live too early"
[ "$(code "/v1/matches/$MATCH/ready" "{\"playerId\":\"$P4\"}")" = "201" ] || fail "last ready rejected"
[ "$(curl -sS "$BASE/v1/matches/$MATCH" | J .match.status)" = "live" ] || fail "match did not go live"

say "websocket: finished event reaches a subscriber"
WS_LOG=$(mktemp)
node -e '
const [id, port, out] = process.argv.slice(1);
const fs = require("fs");
const ws = new WebSocket("ws://localhost:" + port + "/ws?topic=match:" + id);
const timer = setTimeout(() => { try { fs.writeFileSync(out, "timeout"); } catch {} process.exit(1); }, 10000);
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ready") fs.writeFileSync(out, "ready");
  if (m.type === "match" && m.event === "finished") {
    clearTimeout(timer);
    fs.writeFileSync(out, "finished:" + m.winner);
    ws.close();
    process.exit(0);
  }
};
ws.onerror = () => { try { fs.writeFileSync(out, "error"); } catch {} process.exit(1); };
' "$MATCH" "$PORT" "$WS_LOG" &
WS_PID=$!
for _ in $(seq 1 40); do [ -s "$WS_LOG" ] && break; sleep 0.1; done

say "result: Elo is zero-sum"
RESULT=$(post "/v1/matches/$MATCH/result" '{"winner":"A"}')
[ "$(printf '%s' "$RESULT" | J .status)" = "finished" ] || fail "result did not finish the match"
[ "$(printf '%s' "$RESULT" | J .winner)" = "A" ] || fail "winner not stored"
wait "$WS_PID" || true
grep -q 'finished:A' "$WS_LOG" || fail "websocket did not receive finished (log: $(cat "$WS_LOG" 2>/dev/null))"

VIEW=$(curl -sS "$BASE/v1/matches/$MATCH")
SUM=$(printf '%s' "$VIEW" | jq '[.members[].delta] | add')
[ "$SUM" = "0" ] || fail "Elo deltas are not zero-sum: $SUM"
P1RATING=$(curl -sS "$BASE/v1/players/$P1" | J .rating)
[ "$P1RATING" -eq 1216 ] || fail "winner rating is $P1RATING, want 1216"
[ "$(curl -sS "$BASE/v1/leaderboard?limit=1" | J '.[0].name')" = "P4" ] || fail "leaderboard is not sorted by rating"
[ "$(code "/v1/matches/$MATCH/result" '{"winner":"B"}')" = "409" ] || fail "second result should be 409"

say "archive: consumer writes the snapshot to S3"
ARCHIVE=""
for _ in $(seq 1 40); do
  ARCHIVE=$(curl -sS "$BASE/v1/matches/$MATCH/archive")
  printf '%s' "$ARCHIVE" | jq -e '.key' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s' "$ARCHIVE" | jq -e '.key' >/dev/null 2>&1 || fail "archive object was not created"
[ "$(printf '%s' "$ARCHIVE" | jq -r '.content | fromjson | .winner')" = "A" ] || fail "archive has the wrong winner"
[ "$(curl -sS "$BASE/v1/stats" | J .archived)" = "1" ] || fail "stats.archived is not 1"

say "sweep: ready-timeout cancels and requeues four players"
for p in "$P1" "$P2" "$P3" "$P4"; do
  code /v1/queue "{\"playerId\":\"$p\"}" >/dev/null
done
MATCH2=""
for _ in $(seq 1 60); do
  T=$(curl -sS "$BASE/v1/queue/$P2")
  [ "$(printf '%s' "$T" | J .status)" = "matched" ] && MATCH2=$(printf '%s' "$T" | J .matchId) && break
  sleep 0.5
done
[ -n "$MATCH2" ] && [ "$MATCH2" != null ] || fail "second match was not formed"
SWEEP=$(post /v1/sweep '{"now":"2030-01-01T00:00:00Z"}')
[ "$(printf '%s' "$SWEEP" | J .expired)" = "1" ] || fail "sweep did not expire one match"
[ "$(printf '%s' "$SWEEP" | J .requeued)" = "4" ] || fail "sweep did not requeue four players"
[ "$(curl -sS "$BASE/v1/matches/$MATCH2" | J .match.status)" = "cancelled" ] || fail "expired match is not cancelled"

say "errors: unknown match and no dead letters"
[ "$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/matches/nope")" = "404" ] || fail "unknown match should be 404"
[ "$(curl -sS "$BASE/v1/dead" | jq length)" = "0" ] || fail "dead letter queue is not empty: $(curl -sS "$BASE/v1/dead")"

say "stats"
curl -sS "$BASE/v1/stats" | jq .

echo
echo "PASS 046-matchmaking-arena"
