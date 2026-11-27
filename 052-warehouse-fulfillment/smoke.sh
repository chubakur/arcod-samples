#!/usr/bin/env bash
# 052-warehouse-fulfillment: a 3PL warehouse. Orders are allocated FEFO across
# lots by a consumer, picking documents and shipping labels are real objects in
# S3, the carrier is an external API, an expired lot is written off by the
# planner, and a receipt wakes backordered orders.
# Five external systems: postgres, redis, minio, the carrier (host mock) and a
# websocket feed. Four consumers: allocate, buildPick, shipOrder, restock.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8090}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
CARRIER_PORT="${CARRIER_PORT:-9094}"
LOG=/tmp/arcod-052.log
MOCKLOG=/tmp/arcod-052-mock.log
BODY=/tmp/arcod-052-body.json
COMPOSE=.arcod/build/docker-compose.yml

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:-$BODY}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" >/dev/null 2>&1 || true
  docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

pkill -f 'mocks/carrier.mjs' >/dev/null 2>&1 || true
docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true

json_post() { curl -sS -o "$BODY" -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
json_get() { curl -sS -o "$BODY" -w '%{http_code}' "$BASE$1"; }
post() { json_post "$1" "$2" >/dev/null; cat "$BODY"; }
getj() { json_get "$1" >/dev/null; cat "$BODY"; }
code() { json_post "$1" "$2"; }

wait_order() {
  local id="$1" want="$2"
  for _ in $(seq 1 320); do
    json_get "/v1/orders/$id" >/dev/null 2>&1 || true
    local s
    s=$(J .order.status 2>/dev/null || echo new)
    if [ "$s" = "$want" ]; then return 0; fi
    sleep 0.25
  done
  return 1
}

product_id() { getj /v1/products | jq -r --arg sku "$1" '.[]|select(.sku==$sku)|.id'; }
submit() { # clientRef customer lines-json -> order id
  json_post /v1/orders "{\"clientRef\":\"$1\",\"customer\":\"$2\",\"address\":\"1 Main St\",\"lines\":$3}" >/dev/null
  J .id
}

say "check"
$ARCOD check >/dev/null

say "build"
$ARCOD build --impl --port "$PORT" >/dev/null

say "carrier mock on the host (:9094)"
node mocks/carrier.mjs >"$MOCKLOG" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "http://localhost:$CARRIER_PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://localhost:$CARRIER_PORT/healthz" >/dev/null || { cat "$MOCKLOG"; fail "carrier mock did not start"; }

say "run"
$ARCOD run --impl --port "$PORT" >"$LOG" 2>&1 &
RUN_PID=$!
for _ in $(seq 1 240); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -100 "$LOG"; fail "service did not start"; }

say "catalogue: three SKUs, duplicate 409, bad sku 400"
[ "$(json_post /v1/products '{"sku":"sku-widget","name":"Widget","reorderPoint":5}')" = "201" ] || fail "widget must be 201"
W=$(product_id sku-widget); [ -n "$W" ] || fail "widget id missing"
[ "$(json_post /v1/products '{"sku":"sku-gadget","name":"Gadget","reorderPoint":2}')" = "201" ] || fail "gadget must be 201"
G=$(product_id sku-gadget); [ -n "$G" ] || fail "gadget id missing"
[ "$(json_post /v1/products '{"sku":"sku-bolt","name":"Bolt","reorderPoint":3}')" = "201" ] || fail "bolt must be 201"
BOLT=$(product_id sku-bolt); [ -n "$BOLT" ] || fail "bolt id missing"
[ "$(json_post /v1/products '{"sku":"sku-seal","name":"Seal","reorderPoint":5}')" = "201" ] || fail "seal must be 201"
SEAL=$(product_id sku-seal); [ -n "$SEAL" ] || fail "seal id missing"
[ "$(json_post /v1/products '{"sku":"sku-widget","name":"Again"}')" = "409" ] || fail "duplicate sku must be 409"
[ "$(json_post /v1/products '{"sku":"","name":"Nope"}')" = "400" ] || fail "empty sku must be 400"
[ "$(json_post /v1/products '{"sku":"sku-bad","name":"Nope","reorderPoint":-1}')" = "400" ] || fail "negative reorderPoint must be 400"
[ "$(getj /v1/products | jq 'length')" = "4" ] || fail "four products expected"

say "inbound: lots in bins, FEFO order, duplicate code 409, qty 0 400"
[ "$(json_post "/v1/products/$W/receipts" '{"code":"B-W2","qty":5,"expiresAt":"2027-06-30T00:00:00Z","bin":"A-02"}')" = "201" ] || fail "B-W2 must be 201"
[ "$(json_post "/v1/products/$W/receipts" '{"code":"B-W1","qty":10,"expiresAt":"2027-12-31T00:00:00Z","bin":"A-01"}')" = "201" ] || fail "B-W1 must be 201"
[ "$(json_post "/v1/products/$G/receipts" '{"code":"B-G1","qty":2,"expiresAt":"2027-12-31T00:00:00Z","bin":"B-01"}')" = "201" ] || fail "B-G1 must be 201"
[ "$(json_post "/v1/products/$BOLT/receipts" '{"code":"B-B1","qty":4,"expiresAt":"2027-12-31T00:00:00Z","bin":"C-01"}')" = "201" ] || fail "B-B1 must be 201"
[ "$(json_post "/v1/products/$SEAL/receipts" '{"code":"B-S1","qty":3,"expiresAt":"2027-01-01T00:00:00Z","bin":"D-01"}')" = "201" ] || fail "B-S1 must be 201"
[ "$(json_post "/v1/products/$W/receipts" '{"code":"B-W1","qty":1,"expiresAt":"2027-12-31T00:00:00Z"}')" = "409" ] || fail "duplicate batch code must be 409"
[ "$(json_post "/v1/products/$W/receipts" '{"code":"B-ZERO","qty":0,"expiresAt":"2027-12-31T00:00:00Z"}')" = "400" ] || fail "zero qty must be 400"
[ "$(json_post "/v1/products/$W/receipts" '{"code":"B-BAD","qty":1,"expiresAt":"tomorrow"}')" = "400" ] || fail "bad expiry must be 400"
[ "$(json_post "/v1/products/nope/receipts" '{"code":"B-X","qty":1,"expiresAt":"2027-12-31T00:00:00Z"}')" = "404" ] || fail "unknown product receipt must be 404"
[ "$(getj "/v1/products/$W" | jq -r .product.onHand)" = "15" ] || fail "widget onHand must be 15"
[ "$(getj "/v1/products/$W" | jq -r '.batches[0].code')" = "B-W2" ] || fail "batches must be sorted by expiry"
[ "$(getj "/v1/products/$W" | jq -r '.batches[0].bin')" = "A-02" ] || fail "bin not stored"

say "order 1: FEFO allocation, pick list, shipment and label"
O1=$(submit ord-1 Ann '[{"sku":"sku-widget","qty":2},{"sku":"sku-gadget","qty":1}]')
[ -n "$O1" ] || fail "order id missing"
[ "$(J .status)" = "new" ] || fail "a fresh order must be new"
wait_order "$O1" picking || { getj "/v1/orders/$O1"; fail "order 1 did not reach picking"; }
V1=$(getj "/v1/orders/$O1")
[ "$(printf '%s' "$V1" | jq -r .order.allocatedUnits)" = "3" ] || fail "order 1 must allocate 3 units"
[ "$(printf '%s' "$V1" | jq -r '[.reservations[]|select(.qty==2)]|length')" = "1" ] || fail "widget reservation missing"
WIDGET_RES=$(printf '%s' "$V1" | jq -r '.reservations[]|select(.qty==2)|.batchId')
[ "$(printf '%s' "$V1" | jq -r --arg b "$WIDGET_RES" '[.reservations[]|select(.batchId==$b)]|length')" = "1" ] || fail "one reservation per lot expected"
[ "$(printf '%s' "$V1" | jq -r '.reservations[]|select(.qty==1)|.status')" = "held" ] || fail "reservations must be held"
PICK1=$(getj "/v1/orders/$O1/picklist")
[ "$(printf '%s' "$PICK1" | jq -r .key)" = "picks/$O1.json" ] || fail "picklist key mismatch"
[ "$(printf '%s' "$PICK1" | jq -r '.content|fromjson|.units')" = "3" ] || fail "picklist units must be 3"
[ "$(printf '%s' "$PICK1" | jq -r '.content|fromjson|[.lines[]|select(.batch=="B-W2" and .qty==2 and .bin=="A-02")]|length')" = "1" ] || fail "FEFO must take the earlier lot"
[ "$(printf '%s' "$PICK1" | jq -r '.content|fromjson|[.lines[]|select(.batch=="B-G1" and .bin=="B-01")]|length')" = "1" ] || fail "gadget line missing from picklist"
[ "$(curl -sS "http://localhost:$CARRIER_PORT/stats" | jq -r .calls)" = "0" ] || fail "no carrier call before ship"

say "idempotency: the same clientRef returns the same order"
REPEAT=$(post /v1/orders '{"clientRef":"ord-1","customer":"Ann","address":"1 Main St","lines":[{"sku":"sku-widget","qty":2},{"sku":"sku-gadget","qty":1}]}')
[ "$(printf '%s' "$REPEAT" | J .id)" = "$O1" ] || fail "repeat must return the original order"
[ "$(getj /v1/orders | jq 'length')" = "1" ] || fail "repeat must not create a second order"

say "ship: 200, consumer calls the carrier, label in S3, stock leaves"
[ "$(json_post "/v1/orders/$O1/ship" '{"carrier":"post"}')" = "200" ] || fail "ship must answer 200"
wait_order "$O1" shipped || fail "order 1 did not ship"
S1=$(getj "/v1/orders/$O1")
TRK=$(printf '%s' "$S1" | jq -r .order.tracking)
[ "$(printf '%s' "$TRK" | grep -c '^POST-TRK-')" = "1" ] || fail "tracking number missing"
[ "$(printf '%s' "$S1" | jq -r '[.reservations[]|select(.status!="shipped")]|length')" = "0" ] || fail "reservations must be shipped"
[ "$(printf '%s' "$S1" | jq -r '.shipments|length')" = "1" ] || fail "shipment row missing"
LBL=$(getj "/v1/orders/$O1/label")
[ "$(printf '%s' "$LBL" | jq -r .key)" = "labels/$O1.txt" ] || fail "label key mismatch"
printf '%s' "$LBL" | jq -r .content | grep -q "$TRK" || fail "label must carry the tracking number"
[ "$(getj "/v1/products/$W" | jq -r .product.onHand)" = "13" ] || fail "widget onHand must drop to 13"
[ "$(getj "/v1/products/$W" | jq -r .product.reserved)" = "0" ] || fail "widget reserved must drop to 0"
[ "$(json_post "/v1/orders/$O1/ship" '{}')" = "409" ] || fail "second ship must be 409"
[ "$(json_post "/v1/orders/$O1/cancel" '{}')" = "409" ] || fail "cancel after ship must be 409"

say "order 2: cancel returns the units to their lots"
O2=$(submit ord-2 Bob '[{"sku":"sku-widget","qty":5}]')
wait_order "$O2" picking || fail "order 2 did not reach picking"
[ "$(getj "/v1/products/$W" | jq -r .product.reserved)" = "5" ] || fail "order 2 must reserve 5"
[ "$(json_post "/v1/orders/$O2/cancel" '{}')" = "200" ] || fail "cancel must answer 200"
C2=$(cat "$BODY")
[ "$(printf '%s' "$C2" | J .status)" = "cancelled" ] || fail "cancel did not stick"
[ "$(printf '%s' "$C2" | jq -r '.reservations|length')" = "0" ] || fail "cancel response must not invent reservations"
[ "$(getj "/v1/products/$W" | jq -r .product.reserved)" = "0" ] || fail "cancel must release the reservation"
[ "$(getj "/v1/products/$W" | jq -r .product.onHand)" = "13" ] || fail "cancel must not change onHand"
[ "$(getj "/v1/batches?productId=$W" | jq -r '[.[]|select(.code=="B-W2")][0].remaining')" = "3" ] || fail "B-W2 must have 3 again"
[ "$(getj "/v1/batches?productId=$W" | jq -r '[.[]|select(.code=="B-W1")][0].remaining')" = "10" ] || fail "B-W1 must have 10 again"
[ "$(json_post "/v1/orders/$O2/cancel" '{}')" = "409" ] || fail "second cancel must be 409"

say "order 3: not enough stock -> backordered, then a receipt unblocks it"
O3=$(submit ord-3 Cara '[{"sku":"sku-widget","qty":100}]')
wait_order "$O3" backordered || fail "order 3 must be backordered"
V3=$(getj "/v1/orders/$O3")
[ "$(printf '%s' "$V3" | jq -r .order.allocatedUnits)" = "13" ] || fail "order 3 must allocate all 13 available units"
[ "$(printf '%s' "$V3" | jq -r '.pickList|length')" = "0" ] || fail "a short order must not get a picklist"
[ "$(json_post "/v1/products/$W/receipts" '{"code":"B-W3","qty":100,"expiresAt":"2027-12-31T00:00:00Z","bin":"A-03"}')" = "201" ] || fail "B-W3 must be 201"
wait_order "$O3" picking || fail "the restock consumer did not unblock order 3"
[ "$(getj "/v1/orders/$O3" | jq -r .order.allocatedUnits)" = "100" ] || fail "order 3 must allocate 100"
[ "$(getj "/v1/products/$W" | jq -r .product.onHand)" = "113" ] || fail "widget onHand must be 113"
[ "$(getj "/v1/products/$W" | jq -r .product.reserved)" = "100" ] || fail "widget reserved must be 100"

say "order 4: carrier outage, retries, dead letter, order stays shipping"
O4=$(submit ord-4 Dan '[{"sku":"sku-bolt","qty":2}]')
wait_order "$O4" picking || fail "order 4 did not reach picking"
[ "$(json_post "/v1/orders/$O4/ship" '{"carrier":"down"}')" = "200" ] || fail "ship must answer 200"
for _ in $(seq 1 80); do
  json_get /v1/dead >/dev/null 2>&1 || true
  [ "$(J 'length' 2>/dev/null || echo 0)" -ge 1 ] && break
  sleep 0.5
done
[ "$(getj /v1/dead | jq 'length')" = "1" ] || fail "carrier outage must reach the dead letter"
getj /v1/dead | jq -r '.[0].entry.lastError' | grep -q 'carrier network unavailable' || fail "dead letter must explain the carrier error"
[ "$(getj "/v1/orders/$O4" | jq -r .order.status)" = "shipping" ] || fail "order 4 must stay shipping"
[ "$(getj "/v1/orders/$O4" | jq -r '.shipments|length')" = "0" ] || fail "no shipment on a failed carrier call"

say "websocket: allocation and picking events for a new order"
WS_LOG=$(mktemp)
node -e '
const [topic, port, out] = process.argv.slice(1);
const fs = require("fs");
const ws = new WebSocket("ws://localhost:" + port + "/ws?topic=" + topic);
const timer = setTimeout(() => { try { fs.writeFileSync(out, "timeout"); } catch {} process.exit(1); }, 25000);
ws.onmessage = (e) => { try { fs.appendFileSync(out, e.data + "\n"); } catch {} };
ws.onerror = () => { try { fs.writeFileSync(out, "error"); } catch {} process.exit(1); };
' ops "$PORT" "$WS_LOG" &
WS_PID=$!
sleep 1
O5=$(submit ord-5 Eve '[{"sku":"sku-gadget","qty":1}]')
wait_order "$O5" picking || fail "order 5 did not reach picking"
for _ in $(seq 1 60); do grep -q "$O5" "$WS_LOG" 2>/dev/null && break; sleep 0.25; done
grep -q "\"orderId\":\"$O5\"" "$WS_LOG" || fail "websocket did not receive the order (log: $(cat "$WS_LOG" 2>/dev/null))"
grep -q '"event":"allocated"' "$WS_LOG" || fail "websocket did not receive allocated"
grep -q '"event":"picking"' "$WS_LOG" || fail "websocket did not receive picking"
kill "$WS_PID" >/dev/null 2>&1 || true

say "planner: expired lot written off, replenishment proposed, idempotent second run"
[ "$(json_post /v1/planner/run '{"now":"2027-06-01T00:00:00Z"}')" = "201" ] || fail "planner must answer 201"
PLAN=$(cat "$BODY")
[ "$(printf '%s' "$PLAN" | jq -r .expired)" = "1" ] || fail "one expired lot expected"
[ "$(printf '%s' "$PLAN" | jq -r .writtenOff)" = "3" ] || fail "three units must be written off"
[ "$(printf '%s' "$PLAN" | jq -r .proposals)" -ge 1 ] || fail "at least one replenishment expected"
[ "$(getj "/v1/products/$SEAL" | jq -r .product.onHand)" = "0" ] || fail "seal onHand must be 0 after writeoff"
[ "$(getj /v1/replenishments | jq -r --arg p "$SEAL" '[.[]|select(.productId==$p)]|length')" = "1" ] || fail "seal proposal missing"
[ "$(getj /v1/replenishments | jq -r --arg p "$SEAL" '[.[]|select(.productId==$p)][0].suggestedQty')" = "10" ] || fail "seal suggested qty must be 10"
COUNT_BEFORE=$(getj /v1/replenishments | jq 'length')
[ "$(json_post /v1/planner/run '{"now":"2027-06-01T00:00:00Z"}')" = "201" ] || fail "second planner run must answer 201"
[ "$(cat "$BODY" | jq -r .expired)" = "0" ] || fail "second run must not expire anything"
[ "$(getj /v1/replenishments | jq 'length')" = "$COUNT_BEFORE" ] || fail "second run must not duplicate proposals"

say "stats: counters and units"
ST=$(getj /v1/stats)
[ "$(printf '%s' "$ST" | jq -r .orders)" = "5" ] || fail "stats orders must be 5"
[ "$(printf '%s' "$ST" | jq -r .shipped)" = "1" ] || fail "stats shipped must be 1"
[ "$(printf '%s' "$ST" | jq -r .cancelled)" = "1" ] || fail "stats cancelled must be 1"
[ "$(printf '%s' "$ST" | jq -r .shipping)" = "1" ] || fail "stats shipping must be 1"
[ "$(printf '%s' "$ST" | jq -r .picking)" = "2" ] || fail "stats picking must be 2"
[ "$(printf '%s' "$ST" | jq -r .unitsOnHand)" = "118" ] || fail "unitsOnHand must be 118, got $(printf '%s' "$ST" | jq -r .unitsOnHand)"
[ "$(printf '%s' "$ST" | jq -r .unitsReserved)" = "103" ] || fail "unitsReserved must be 103, got $(printf '%s' "$ST" | jq -r .unitsReserved)"
[ "$(printf '%s' "$ST" | jq -r .products)" = "4" ] || fail "stats products must be 4"

say "validation and 404"
[ "$(json_post /v1/orders '{"clientRef":"bad-1","customer":"X","address":"Y","lines":[]}')" = "400" ] || fail "empty lines must be 400"
[ "$(json_post /v1/orders '{"clientRef":"bad-2","customer":"X","address":"Y","lines":[{"sku":"sku-ghost","qty":1}]}')" = "404" ] || fail "unknown sku must be 404"
[ "$(json_post /v1/orders '{"clientRef":"bad-3","customer":"X","address":"Y","lines":[{"sku":"sku-widget","qty":0}]}')" = "400" ] || fail "zero line qty must be 400"
[ "$(json_get /v1/orders/nope)" = "404" ] || fail "unknown order must be 404"
[ "$(json_get /v1/products/nope)" = "404" ] || fail "unknown product must be 404"
[ "$(json_get /v1/orders/nope/picklist)" = "404" ] || fail "unknown picklist must be 404"
[ "$(json_get /v1/orders/$O2/label)" = "404" ] || fail "cancelled order has no label"
[ "$(json_post "/v1/orders/$O2/ship" '{}')" = "409" ] || fail "shipping a cancelled order must be 409"

say "PASS"
