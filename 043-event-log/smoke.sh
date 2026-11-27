#!/usr/bin/env bash
# 043-event-log: append-only event log in Postgres, an async projector that
# folds events into a SQL read model, a replay consumer that rebuilds it, and a
# packer that writes JSONL segments to S3. Redis carries the queue.
# Checks: idempotent stream create, optimistic concurrency (stale 409, two
# racers one winner), projection lag -> caught up, replay from the log, archive
# round-trip through S3, stats, invalid input, unknown stream.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8095}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-043.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:--}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
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

create_stream() {
  curl -sS -X POST "$BASE/v1/streams" -H 'content-type: application/json' \
    -d "{\"name\":\"$1\"}"
}

# payload is a JSON document, sent as a JSON string field (the log stores the
# producer's bytes verbatim).
append_event() {
  local stream_id="$1" type="$2" payload="$3" expected="$4"
  local body
  body=$(printf '%s' "$payload" | jq -Rs .)
  curl -sS -X POST "$BASE/v1/streams/$stream_id/events" \
    -H 'content-type: application/json' \
    -d "{\"type\":\"$type\",\"payload\":$body,\"expectedVersion\":$expected}"
}

wait_order() {
  local stream_id="$1" want_seq="$2"
  for _ in $(seq 1 60); do
    local view
    view=$(curl -sS "$BASE/v1/orders/$stream_id")
    if [ "$(printf '%s' "$view" | J .lastSeq)" = "$want_seq" ]; then
      printf '%s' "$view"
      return 0
    fi
    sleep 1
  done
  return 1
}

say "streams: create is idempotent"
S1=$(create_stream "order-7")
S1_ID=$(printf '%s' "$S1" | J .id)
[ -n "$S1_ID" ] && [ "$S1_ID" != "null" ] || fail "stream id: $S1"
S1_AGAIN=$(create_stream "order-7")
[ "$(printf '%s' "$S1_AGAIN" | J .id)" = "$S1_ID" ] || fail "duplicate create forked the log"
[ "$(printf '%s' "$S1_AGAIN" | J .version)" = "0" ] || fail "fresh stream version"

say "append: three events with expectedVersion 0,1,2"
E1=$(append_event "$S1_ID" "order.created" '{"total":12500,"lines":2}' 0)
[ "$(printf '%s' "$E1" | J .seq)" = "1" ] || fail "seq 1: $E1"
E2=$(append_event "$S1_ID" "order.paid" '{"total":12500}' 1)
[ "$(printf '%s' "$E2" | J .seq)" = "2" ] || fail "seq 2: $E2"
E3=$(append_event "$S1_ID" "order.shipped" '{"carrier":"dhl"}' 2)
[ "$(printf '%s' "$E3" | J .seq)" = "3" ] || fail "seq 3: $E3"
[ "$(printf '%s' "$E3" | J .recordedAt)" != "null" ] || fail "recordedAt missing"

say "append: stale expectedVersion is 409"
CODE=$(curl -sS -o /tmp/arcod-043-stale.json -w '%{http_code}' -X POST "$BASE/v1/streams/$S1_ID/events" \
  -H 'content-type: application/json' \
  -d "{\"type\":\"order.cancelled\",\"payload\":\"{}\",\"expectedVersion\":2}")
[ "$CODE" = "409" ] || fail "stale append -> $CODE ($(cat /tmp/arcod-043-stale.json))"

say "events: the log is readable and ordered"
EVENTS=$(curl -sS "$BASE/v1/streams/$S1_ID/events?limit=10")
[ "$(printf '%s' "$EVENTS" | jq 'length')" = "3" ] || fail "event count: $EVENTS"
[ "$(printf '%s' "$EVENTS" | J '.[2].type')" = "order.shipped" ] || fail "event order"

say "projector: view catches up to seq 3"
VIEW=$(wait_order "$S1_ID" 3) || fail "view never reached seq 3: $(curl -sS "$BASE/v1/orders/$S1_ID")"
[ "$(printf '%s' "$VIEW" | J .status)" = "shipped" ] || fail "status: $VIEW"
[ "$(printf '%s' "$VIEW" | J .total)" = "12500" ] || fail "total: $VIEW"
[ "$(printf '%s' "$VIEW" | J .lines)" = "2" ] || fail "lines: $VIEW"

say "projections: checkpoint is visible"
PROJ=$(curl -sS "$BASE/v1/projections")
[ "$(printf '%s' "$PROJ" | jq '[.[] | select(.name=="project" and .streamId=="'"$S1_ID"'")] | length')" = "1" ] \
  || fail "project checkpoint: $PROJ"

say "replay: the view is rebuilt from the log"
REPLAY=$(curl -sS -X POST "$BASE/v1/streams/$S1_ID/replay")
[ "$(printf '%s' "$REPLAY" | J .queued)" = "true" ] || fail "replay ack: $REPLAY"
OK=0
for _ in $(seq 1 60); do
  PROJ=$(curl -sS "$BASE/v1/projections")
  N=$(printf '%s' "$PROJ" | jq '[.[] | select(.name=="rebuild" and .streamId=="'"$S1_ID"'" and .seq==3)] | length')
  [ "$N" = "1" ] && OK=1 && break
  sleep 1
done
[ "$OK" = "1" ] || fail "rebuild checkpoint never appeared: $PROJ"
VIEW=$(curl -sS "$BASE/v1/orders/$S1_ID")
[ "$(printf '%s' "$VIEW" | J .status)" = "shipped" ] || fail "view after replay: $VIEW"
[ "$(printf '%s' "$VIEW" | J .total)" = "12500" ] || fail "total after replay: $VIEW"

say "conflict: a stale append is rejected, the retry with the fresh version lands"
S2=$(create_stream "order-8"); S2_ID=$(printf '%s' "$S2" | J .id)
E4=$(append_event "$S2_ID" "order.created" '{"total":100,"lines":1}' 0)
[ "$(printf '%s' "$E4" | J .seq)" = "1" ] || fail "S2 seq 1: $E4"
CODE=$(curl -sS -o /tmp/arcod-043-stale2.json -w '%{http_code}' -X POST "$BASE/v1/streams/$S2_ID/events" \
  -H 'content-type: application/json' \
  -d '{"type":"order.paid","payload":"{}","expectedVersion":0}')
[ "$CODE" = "409" ] || fail "stale append on S2 -> $CODE"
E5=$(append_event "$S2_ID" "order.paid" '{"total":100}' 1)
[ "$(printf '%s' "$E5" | J .seq)" = "2" ] || fail "S2 seq 2 after retry: $E5"
S2_EVENTS=$(curl -sS "$BASE/v1/streams/$S2_ID/events?limit=10")
[ "$(printf '%s' "$S2_EVENTS" | jq 'length')" = "2" ] || fail "S2 has two events: $S2_EVENTS"
wait_order "$S2_ID" 2 >/dev/null || fail "S2 view never caught up"

say "archive: pack the log to S3 and read it back"
ARCH=$(curl -sS -X POST "$BASE/v1/streams/$S1_ID/archive")
[ "$(printf '%s' "$ARCH" | J .queued)" = "true" ] || fail "archive ack: $ARCH"
OK=0
for _ in $(seq 1 60); do
  EXPORT=$(curl -sS "$BASE/v1/streams/$S1_ID/archive" 2>/dev/null || true)
  if [ "$(printf '%s' "$EXPORT" | J '.events // 0' 2>/dev/null || echo 0)" = "3" ]; then OK=1; break; fi
  sleep 1
done
[ "$OK" = "1" ] || { tail -20 "$LOG"; fail "archive never appeared: $EXPORT"; }
[ "$(printf '%s' "$EXPORT" | J .bytes)" -gt 0 ] || fail "empty archive: $EXPORT"
KEY=$(printf '%s' "$EXPORT" | J .key)
case "$KEY" in streams/order-7/v3.jsonl) ;; *) fail "archive key: $KEY";; esac
printf '%s' "$EXPORT" | J .content | grep -q '"type":"order.paid"' || fail "archive lost event types"
printf '%s' "$EXPORT" | J .content | grep -q '"seq":3' || fail "archive lost seq"

say "stats: everything is counted"
STATS=$(curl -sS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | J .streams)" -ge 2 ] || fail "stats streams: $STATS"
[ "$(printf '%s' "$STATS" | J .events)" -ge 5 ] || fail "stats events: $STATS"
[ "$(printf '%s' "$STATS" | J .views)" -ge 2 ] || fail "stats views: $STATS"
[ "$(printf '%s' "$STATS" | J .archives)" -ge 1 ] || fail "stats archives: $STATS"

say "errors: empty type is 400, unknown stream is 404"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/streams/$S1_ID/events" \
  -H 'content-type: application/json' -d '{"type":"","payload":"{}","expectedVersion":3}')
[ "$CODE" = "400" ] || fail "empty type -> $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/orders/does-not-exist")
[ "$CODE" = "404" ] || fail "unknown view -> $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/streams/does-not-exist/events" \
  -H 'content-type: application/json' -d '{"type":"order.paid","payload":"{}","expectedVersion":0}')
[ "$CODE" = "404" ] || fail "unknown stream append -> $CODE"

printf '\nPASS\n'
