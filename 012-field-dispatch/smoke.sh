#!/usr/bin/env bash
# End-to-end: mysql + rabbitmq + minio + external routing gateway.
# Open ticket -> queue consumer assigns a technician -> complete with photos
# in S3 -> notification consumer -> queue drained.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8097}"
ROUTER_PORT="${ROUTER_PORT:-9098}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
ROUTER_LOG=/tmp/arcod-012-router.jsonl
MOCK_PID=""

fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "- $*"; }

cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

PORT="$ROUTER_PORT" ROUTER_FILE="$ROUTER_LOG" node mock/router.mjs >/tmp/arcod-012-mock.log 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  if curl -fsS "http://localhost:${ROUTER_PORT}/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
curl -fsS "http://localhost:${ROUTER_PORT}/healthz" >/dev/null || fail "router mock is not up"

"$ARCOD" check >/dev/null
"$ARCOD" build --impl --port "$PORT" >/dev/null
"$ARCOD" run --impl --port "$PORT" >/tmp/arcod-sample-012.log 2>&1 &
for _ in $(seq 1 150); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy"
say "health: ok (service + mysql + redis + minio + router mock)"

# 1. Two technicians on shift in Moscow.
T1=$(curl -fsS -X POST "$BASE/v1/technicians" -H 'content-type: application/json' \
  -d '{"name":"Ivan Petrov","city":"Moscow","skills":["plumbing","heating"]}')
[ "$(printf '%s' "$T1" | jq -r .name)" = "Ivan Petrov" ] || fail "technician not stored"
T2=$(curl -fsS -X POST "$BASE/v1/technicians" -H 'content-type: application/json' \
  -d '{"name":"Olga Smirnova","city":"Moscow","skills":["electrics"]}')
[ "$(printf '%s' "$T2" | jq -r .city)" = "Moscow" ] || fail "technician city lost"
say "technicians: 2 registered"

# 2. Open a ticket: HTTP ack is 'queued', the consumer assigns.
TICKET=$(curl -fsS -X POST "$BASE/v1/tickets" -H 'content-type: application/json' \
  -d '{"customer":"ACME","email":"ops@acme.test","city":"Moscow","address":"Tverskaya 1","category":"plumbing","priority":1}')
ID=$(printf '%s' "$TICKET" | jq -r .id)
CODE=$(printf '%s' "$TICKET" | jq -r .code)
[ "$(printf '%s' "$TICKET" | jq -r .status)" = "queued" ] || fail "ticket is not queued on create"
case "$CODE" in DSP-*) ;; *) fail "ticket code not generated" ;; esac
say "ticket $CODE queued"

STATUS=""
for _ in $(seq 1 40); do
  GOT=$(curl -fsS "$BASE/v1/tickets/$ID")
  STATUS=$(printf '%s' "$GOT" | jq -r .status)
  [ "$STATUS" = "assigned" ] && break
  sleep 0.5
done
[ "$STATUS" = "assigned" ] || fail "consumer did not assign the ticket (status=$STATUS)"
[ "$(printf '%s' "$GOT" | jq -r .technician)" = "Ivan Petrov" ] || fail "wrong technician assigned"
[ "$(printf '%s' "$GOT" | jq -r .etaMinutes)" -gt 0 ] || fail "eta missing"
say "consumer: assigned to Ivan Petrov, eta $(printf '%s' "$GOT" | jq -r .etaMinutes)m"

# 3. The offer really went to the external routing service.
grep -q '"kind":"offer"' "$ROUTER_LOG" || fail "router never received an offer"
say "router: offer recorded"

# 4. Board and counts (count() instead of scanning the table).
BOARD=$(curl -fsS "$BASE/v1/tickets?city=Moscow&status=assigned")
[ "$(printf '%s' "$BOARD" | jq 'length')" = "1" ] || fail "board filter is wrong"
STATS=$(curl -fsS "$BASE/v1/stats?city=Moscow")
[ "$(printf '%s' "$STATS" | jq -r .assigned)" = "1" ] || fail "stats.assigned != 1"
[ "$(printf '%s' "$STATS" | jq -r .done)" = "0" ] || fail "stats.done != 0"
say "board: 1 assigned; stats: assigned=1 done=0"

# 5. Completion writes photos to S3 and publishes the notification job.
DONE=$(curl -fsS -X POST "$BASE/v1/tickets/$ID/complete" -H 'content-type: application/json' \
  -d '{"note":"Replaced the mixer","photos":[{"key":"before.txt","body":"before: leak","type":"text/plain"},{"key":"after.txt","body":"after: dry","type":"text/plain"}]}')
[ "$(printf '%s' "$DONE" | jq -r .status)" = "done" ] || fail "ticket not closed"
[ "$(printf '%s' "$DONE" | jq -r .photoKeys)" = "before.txt,after.txt" ] || fail "photo keys not saved"
say "complete: done with 2 photos in S3"

REPORT=$(curl -fsS "$BASE/v1/tickets/$ID/report")
[ "$(printf '%s' "$REPORT" | jq 'length')" = "2" ] || fail "report lost photos"
[ "$(printf '%s' "$REPORT" | jq -r '.[0]')" = "before: leak" ] || fail "report body mismatch"
say "report: 2 attachments read back from S3"

STATS2=$(curl -fsS "$BASE/v1/stats?city=Moscow")
[ "$(printf '%s' "$STATS2" | jq -r .done)" = "1" ] || fail "stats.done != 1 after close"
[ "$(printf '%s' "$STATS2" | jq -r .assigned)" = "0" ] || fail "stats.assigned != 0 after close"

# 6. Second consumer: notification through the gateway.
for _ in $(seq 1 30); do
  grep -q '"kind":"notify"' "$ROUTER_LOG" && break
  sleep 0.5
done
grep -q '"kind":"notify"' "$ROUTER_LOG" || fail "notification consumer never called the gateway"
grep -q "$CODE" "$ROUTER_LOG" || fail "notification does not carry the ticket code"
say "notify consumer: gateway got $CODE"

# 7. Errors behave.
CODE404=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/tickets/00000000-0000-0000-0000-000000000000")
[ "$CODE404" = "404" ] || fail "missing ticket is not 404 ($CODE404)"
CODE409=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/tickets/$ID/complete" \
  -H 'content-type: application/json' -d '{"note":"again","photos":[]}')
[ "$CODE409" = "409" ] || fail "double completion is not 409 ($CODE409)"
say "errors: 404 unknown, 409 double completion"

echo "PASS 012-field-dispatch"
