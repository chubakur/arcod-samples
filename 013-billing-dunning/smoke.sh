#!/usr/bin/env bash
# End-to-end: mysql (kv in arcod_kv) + redis(queue) + minio + external payment gateway.
# Plan -> subscribe -> charge consumer -> receipt in S3; a soft decline goes
# through the dunning consumer and succeeds on the second attempt; a hard
# decline parks the subscription as past_due.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8099}"
GATEWAY_PORT="${GATEWAY_PORT:-9099}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
GATEWAY_LOG=/tmp/arcod-013-gateway.jsonl
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
rm -f "$GATEWAY_LOG"

PORT="$GATEWAY_PORT" GATEWAY_LOG="$GATEWAY_LOG" node mock/gateway.mjs >/tmp/arcod-013-mock.log 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  if curl -fsS "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
curl -fsS "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null || fail "gateway mock is not up"

"$ARCOD" check >/dev/null
"$ARCOD" build --impl --port "$PORT" >/dev/null
"$ARCOD" run --impl --port "$PORT" >/tmp/arcod-sample-013.log 2>&1 &
for _ in $(seq 1 150); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy"
say "health: ok (service + mysql + redis queue + minio + gateway mock)"

wait_status() {
  local id="$1" want="$2"
  for _ in $(seq 1 60); do
    local got
    got=$(curl -fsS "$BASE/v1/invoices/$id" | jq -r .status)
    if [ "$got" = "$want" ]; then return 0; fi
    if [ "$got" = "failed" ] && [ "$want" != "failed" ]; then return 1; fi
    sleep 0.5
  done
  return 1
}

# 1. Price book.
PLAN=$(curl -fsS -X POST "$BASE/v1/plans" -H 'content-type: application/json' \
  -d '{"code":"pro","name":"Pro monthly","priceCents":9900,"intervalDays":30}')
[ "$(printf '%s' "$PLAN" | jq -r .code)" = "pro" ] || fail "plan not stored"
say "plan: pro / 9900 cents / 30 days"

# 2. Happy path: subscribe, the consumer charges, the receipt lands in S3.
SUB=$(curl -fsS -X POST "$BASE/v1/subscriptions" -H 'content-type: application/json' \
  -d '{"planCode":"pro","customer":"ACME","email":"billing@acme.test","cardToken":"tok_ok"}')
SUB_ID=$(printf '%s' "$SUB" | jq -r .id)
INV=$(curl -fsS "$BASE/v1/subscriptions/$SUB_ID/invoices" | jq -r '.[0].id')
[ -n "$INV" ] && [ "$INV" != "null" ] || fail "invoice was not created"
wait_status "$INV" paid || fail "invoice $INV was not paid"
RECEIPT=$(curl -fsS "$BASE/v1/invoices/$INV/receipt")
[ "$(printf '%s' "$RECEIPT" | jq -r .amountCents)" = "9900" ] || fail "receipt has the wrong amount"
[ "$(printf '%s' "$RECEIPT" | jq -r .invoiceId)" = "$INV" ] || fail "receipt points at another invoice"
say "charge: paid, receipt receipts/$INV.json in S3"

# 3. Idempotency: one invoice must produce exactly one gateway call.
CALLS=$(jq -r --arg id "$INV" 'select(.invoiceId == $id) | .idempotencyKey' "$GATEWAY_LOG" | wc -l | tr -d ' ')
[ "$CALLS" = "1" ] || fail "gateway saw $CALLS calls for one invoice (want 1)"
say "idempotency: 1 gateway call for 1 invoice"

# 4. Soft decline: dunning consumer re-arms the charge, second attempt wins.
SUB2=$(curl -fsS -X POST "$BASE/v1/subscriptions" -H 'content-type: application/json' \
  -d '{"planCode":"pro","customer":"Flaky Ltd","email":"ops@flaky.test","cardToken":"tok_flaky"}')
SUB2_ID=$(printf '%s' "$SUB2" | jq -r .id)
INV2=$(curl -fsS "$BASE/v1/subscriptions/$SUB2_ID/invoices" | jq -r '.[0].id')
wait_status "$INV2" paid || fail "flaky invoice was not paid after retry"
ATTEMPTS=$(curl -fsS "$BASE/v1/invoices/$INV2" | jq -r .attempts)
[ "$ATTEMPTS" = "2" ] || fail "expected 2 attempts, got $ATTEMPTS"
say "dunning: declined once, paid on attempt $ATTEMPTS"

# 5. Hard decline: three attempts, then the subscription is past_due.
SUB3=$(curl -fsS -X POST "$BASE/v1/subscriptions" -H 'content-type: application/json' \
  -d '{"planCode":"pro","customer":"Dead Card","email":"dead@example.test","cardToken":"tok_dead"}')
SUB3_ID=$(printf '%s' "$SUB3" | jq -r .id)
INV3=$(curl -fsS "$BASE/v1/subscriptions/$SUB3_ID/invoices" | jq -r '.[0].id')
wait_status "$INV3" failed || fail "dead invoice did not end up failed"
[ "$(curl -fsS "$BASE/v1/invoices/$INV3" | jq -r .lastError)" = "insufficient_funds" ] || fail "wrong lastError"
[ "$(curl -fsS "$BASE/v1/subscriptions/$SUB3_ID" | jq -r .status)" = "past_due" ] || fail "subscription not parked"
say "dunning: 3 declines -> invoice failed, subscription past_due"

# 6. Reads: receipts, invoices, stats, reconciliation sweep.
COUNT=$(curl -fsS "$BASE/v1/subscriptions/$SUB3_ID/invoices" | jq 'length')
[ "$COUNT" = "1" ] || fail "invoice list is wrong"
STATS=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | jq -r .active)" = "2" ] || fail "stats.active is wrong: $STATS"
[ "$(printf '%s' "$STATS" | jq -r .pastDue)" = "1" ] || fail "stats.pastDue is wrong: $STATS"
[ "$(printf '%s' "$STATS" | jq -r .collectedCents)" = "19800" ] || fail "stats.collectedCents is wrong: $STATS"
[ "$(curl -fsS -X POST "$BASE/v1/admin/reconcile" | jq -r .count)" = "0" ] || fail "reconcile found stuck invoices"
say "stats: active=2 past_due=1 collected=19800"

# 7. Paying an already paid invoice is a conflict, not a second charge.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/invoices/$INV/pay")
[ "$CODE" = "409" ] || fail "paying a paid invoice returned $CODE"
say "guard: double payment rejected with 409"

echo "PASS"
