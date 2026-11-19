#!/usr/bin/env bash
# End-to-end: mysql + minio + rabbitmq + external gateway, payment, queue consumer.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8095}"
GW_PORT="${GW_PORT:-9099}"
BASE="http://localhost:${PORT}"
COMPOSE=".arcod/build/docker-compose.yml"
MOCK_PID=""

cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

node mock/gateway.mjs & MOCK_PID=$!
for _ in $(seq 1 30); do
  curl -fsS "http://localhost:${GW_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.3
done
curl -fsS "http://localhost:${GW_PORT}/healthz" >/dev/null

arcod build --impl --port "$PORT" >/dev/null
docker compose -f "$COMPOSE" build >/dev/null
docker compose -f "$COMPOSE" up -d --wait >/dev/null 2>&1 || docker compose -f "$COMPOSE" up -d >/dev/null
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null
say "health: ok (service + mysql + minio + rabbitmq)"

PROD=$(curl -fsS -X POST "$BASE/v1/products" -H 'content-type: application/json' \
  -d '{"sku":"acme-mug","title":"ACME mug","price":1250,"stock":10}')
PID=$(printf '%s' "$PROD" | jq -r .id)
[ "$(printf '%s' "$PROD" | jq -r .sku)" = "acme-mug" ]
say "catalog: product $PID, stock 10"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/products" \
  -H 'content-type: application/json' \
  -d '{"sku":"acme-mug","title":"Second","price":1,"stock":1}')
[ "$CODE" = "409" ]
say "catalog: duplicate sku 409 (unique rule)"

[ "$(curl -sS "$BASE/v1/products/$PID" | jq -r .stock)" = "10" ]

ORDER=$(curl -fsS -X POST "$BASE/v1/orders" -H 'content-type: application/json' \
  -d "{\"product\":\"$PID\",\"qty\":3,\"token\":\"visa-4242\"}")
OID=$(printf '%s' "$ORDER" | jq -r .id)
[ "$(printf '%s' "$ORDER" | jq -r .status)" = "paid" ]
[ "$(printf '%s' "$ORDER" | jq -r .amount)" = "3750" ]
[ "$(printf '%s' "$ORDER" | jq -r .paymentRef)" != "null" ]
say "payment: gateway authorized 3750, order $OID"

for _ in $(seq 1 40); do
  STATUS=$(curl -fsS "$BASE/v1/orders/$OID" | jq -r .status)
  [ "$STATUS" = "packed" ] && break
  sleep 0.5
done
[ "$STATUS" = "packed" ]
say "consumer: order packed from queue"

INV=$(curl -fsS "$BASE/v1/orders/$OID/invoice")
[ "$(printf '%s' "$INV" | jq -r .status)" = "packed" ]
[ "$(printf '%s' "$INV" | jq -r .amount)" = "3750" ]
say "storage: invoice read from s3"

[ "$(curl -sS "$BASE/v1/products/$PID" | jq -r .stock)" = "7" ]
say "stock: 10 -> 7 after order"

DECL=$(curl -fsS -X POST "$BASE/v1/orders" -H 'content-type: application/json' \
  -d "{\"product\":\"$PID\",\"qty\":1,\"token\":\"decline\"}")
[ "$(printf '%s' "$DECL" | jq -r .status)" = "rejected" ]
[ "$(curl -sS "$BASE/v1/products/$PID" | jq -r .stock)" = "7" ]
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/orders/$(printf '%s' "$DECL" | jq -r .id)/invoice")
[ "$CODE" = "409" ]
say "payment: decline leaves stock and no invoice"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/orders" \
  -H 'content-type: application/json' \
  -d "{\"product\":\"$PID\",\"qty\":8,\"token\":\"visa-4242\"}")
[ "$CODE" = "409" ]
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/orders" \
  -H 'content-type: application/json' \
  -d "{\"product\":\"$PID\",\"qty\":0,\"token\":\"visa-4242\"}")
[ "$CODE" = "400" ]
CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
  "$BASE/v1/orders/00000000-0000-0000-0000-000000000000")
[ "$CODE" = "404" ]
say "errors: oversell 409, bad qty 400, unknown order 404"

say "sample 010: PASS"
