#!/usr/bin/env bash
# End-to-end smoke test: build, start the stack, exercise the API, stop it.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8092}"
BASE="http://localhost:$PORT"

cleanup() {
  arcod run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

arcod build --impl >/dev/null
arcod run --impl --port "$PORT" >/tmp/arcod-sample-002.log 2>&1 &
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null

say() { printf '%s\n' "$*"; }
wait_status() {
  local id="$1" want="$2" status=""
  for _ in $(seq 1 60); do
    status=$(curl -fsS "$BASE/v1/events/$id" | jq -r .status)
    if [ "$status" = "$want" ]; then printf '%s' "$status"; return 0; fi
    sleep 0.25
  done
  printf '%s' "$status"
  return 1
}

say "health: ok"

# 1. A normal event is accepted once and delivered by the consumer job.
FIRST=$(curl -fsS -X POST "$BASE/v1/hooks/github" -H 'content-type: application/json' \
  -d '{"key":"evt-1","eventType":"push","payload":"{\"ref\":\"main\"}"}')
ID=$(printf '%s' "$FIRST" | jq -r .event.id)
[ "$(printf '%s' "$FIRST" | jq -r .duplicate)" = "false" ]
[ "$(wait_status "$ID" delivered)" = "delivered" ]
[ "$(curl -fsS "$BASE/v1/events/$ID" | jq -r .attempts)" = "1" ]
say "ingest + deliver: $ID attempts=1"

# 2. The same (source, key) is a duplicate: same event, no second delivery.
AGAIN=$(curl -fsS -X POST "$BASE/v1/hooks/github" -H 'content-type: application/json' \
  -d '{"key":"evt-1","eventType":"push","payload":"{}"}')
[ "$(printf '%s' "$AGAIN" | jq -r .duplicate)" = "true" ]
[ "$(printf '%s' "$AGAIN" | jq -r .event.id)" = "$ID" ]
say "idempotency: duplicate key returns the same event"

# 3. A flaky subscriber: first attempt fails, the queue retries, then succeeds.
FLAKY=$(curl -fsS -X POST "$BASE/v1/hooks/payments" -H 'content-type: application/json' \
  -d '{"key":"pay-7","eventType":"paid","payload":"{}","failFirst":1}')
FID=$(printf '%s' "$FLAKY" | jq -r .event.id)
[ "$(wait_status "$FID" delivered)" = "delivered" ]
[ "$(curl -fsS "$BASE/v1/events/$FID" | jq -r .attempts)" = "2" ]
say "retry: delivered on attempt 2"

# 4. A permanently failing subscriber exhausts the retry budget and is dead.
BROKEN=$(curl -fsS -X POST "$BASE/v1/hooks/payments" -H 'content-type: application/json' \
  -d '{"key":"pay-8","eventType":"paid","payload":"{}","failFirst":9}')
BID=$(printf '%s' "$BROKEN" | jq -r .event.id)
[ "$(wait_status "$BID" dead)" = "dead" ]
[ "$(curl -fsS "$BASE/v1/events/$BID" | jq -r '.attempts >= 3')" = "true" ]
say "dead letter: budget exhausted, status=dead"

# 5. Operator redelivery resets the counters and delivers.
RD=$(curl -fsS -X POST "$BASE/v1/events/$BID/redeliver")
[ "$(printf '%s' "$RD" | jq -r .status)" = "pending" ]
[ "$(wait_status "$BID" delivered)" = "delivered" ]
[ "$(curl -fsS "$BASE/v1/events/$BID" | jq -r .attempts)" = "1" ]
say "redeliver: reset and delivered on attempt 1"

# 6. Listing, stats and error paths.
N=$(curl -fsS "$BASE/v1/events?status=delivered&limit=10" | jq -r '.items | length')
[ "$N" -ge 3 ]
STATS=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | jq -r .received)" = "3" ]
[ "$(printf '%s' "$STATS" | jq -r .delivered)" = "3" ]
say "list/stats: $N delivered, received=3"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/events/00000000-0000-0000-0000-000000000000")
[ "$CODE" = "404" ]
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/hooks/github" \
  -H 'content-type: application/json' -d '{"eventType":"push","payload":"{}"}')
[ "$CODE" = "400" ]
say "errors: unknown event 404, missing key 400"

say "sample 002: PASS"
