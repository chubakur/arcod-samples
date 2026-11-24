#!/usr/bin/env bash
# End-to-end: mysql + redis queue + a mail gateway on the compose network.
# Seed -> lot -> bids (floor, self-outbid, anti-sniping) -> closing tick ->
# consumer mails the seller and the winner -> stats -> idempotent second tick.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8093}"
MAIL_PORT="${MAIL_PORT:-9096}"
BASE="http://localhost:${PORT}"
MAIL="http://localhost:${MAIL_PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
RUN_PID=""
MAILER_NAME="arcod-016-mailer"

fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "- $*"; }

arcod_run() {
  if [ -n "$ARCOD_JS" ]; then node "$ARCOD_JS" "$@"; else "$ARCOD" "$@"; fi
}

cleanup() {
  if [ -n "$RUN_PID" ]; then
    kill "$RUN_PID" >/dev/null 2>&1 || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  docker rm -f "$MAILER_NAME" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker rm -f "$MAILER_NAME" >/dev/null 2>&1 || true
docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

arcod_run check >/dev/null
arcod_run build --impl --port "$PORT" >/dev/null
arcod_run run --impl --port "$PORT" >/tmp/arcod-sample-016.log 2>&1 &
RUN_PID=$!

for _ in $(seq 1 180); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see /tmp/arcod-sample-016.log)"
say "health: ok (service + mysql + redis queue)"

# The mail gateway joins the same compose network under the name the spec
# binds. Its image is the service image, only the entrypoint changes.
IMAGE=$(grep -m1 'image: arcod/auction-service' .arcod/build/docker-compose.yml | awk '{print $2}')
SERVICE_ID=$(docker compose -f .arcod/build/docker-compose.yml ps -q service)
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$SERVICE_ID")
[ -n "$IMAGE" ] && [ -n "$NETWORK" ] || fail "cannot find the service image/network"
docker run -d --name "$MAILER_NAME" -p "${MAIL_PORT}:9096" --network "$NETWORK" --network-alias mailer \
  -v "$PWD/mock:/app" -w /app --entrypoint node "$IMAGE" mailer.mjs >/dev/null
for _ in $(seq 1 60); do
  if curl -fsS "$MAIL/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -fsS "$MAIL/healthz" >/dev/null || fail "mail gateway is not up"
say "mail gateway: ok (mock of the vendor's send API)"

# 1. Demo lots: one with a reserve above the start, one cheap.
curl -fsS -X POST "$BASE/v1/dev/seed" | jq -e '.ok == true' >/dev/null || fail "seed"
say "seed: 2 open lots"

# 2. A lot, one valid bid, then the three refusals.
LOT=$(curl -fsS -X POST "$BASE/v1/lots" -H 'content-type: application/json' \
  -d '{"title":"Vintage poster","seller":"anna","sellerEmail":"anna@arcod.test","startCents":1000,"reserveCents":5000,"durationSec":3600}')
LOT_ID=$(printf '%s' "$LOT" | jq -r .id)
[ -n "$LOT_ID" ] && [ "$LOT_ID" != "null" ] || fail "createLot returned no id"
BID=$(curl -fsS -X POST "$BASE/v1/lots/$LOT_ID/bids" -H 'content-type: application/json' \
  -d '{"bidder":"bob","amountCents":5000}')
[ "$(printf '%s' "$BID" | jq -r .lot.highBidCents)" = "5000" ] || fail "bid was not accepted"
[ "$(printf '%s' "$BID" | jq -r '.bids | length')" = "1" ] || fail "bid row missing"
say "bid: 5000 accepted, lot high updated"

CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/lots/$LOT_ID/bids" \
  -H 'content-type: application/json' -d '{"bidder":"bob","amountCents":9000}')
[ "$CODE" = "409" ] || fail "self-outbid should be 409, got $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/lots/$LOT_ID/bids" \
  -H 'content-type: application/json' -d '{"bidder":"dave","amountCents":5050}')
[ "$CODE" = "400" ] || fail "bid below the increment should be 400, got $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/lots/00000000-0000-0000-0000-000000000000/bids" \
  -H 'content-type: application/json' -d '{"bidder":"dave","amountCents":9000}')
[ "$CODE" = "404" ] || fail "bid on a missing lot should be 404, got $CODE"
say "refusals: self-outbid 409, below floor 400, missing lot 404"

# 3. Anti-sniping: a bid in the last 60 s moves the end by 120 s, once.
SN=$(curl -fsS -X POST "$BASE/v1/lots" -H 'content-type: application/json' \
  -d '{"title":"Snipe target","seller":"ann","sellerEmail":"ann@arcod.test","startCents":100,"reserveCents":100,"durationSec":30}')
SN_ID=$(printf '%s' "$SN" | jq -r .id)
SN_END=$(printf '%s' "$SN" | jq -r .endsAt)
SN_BID=$(curl -fsS -X POST "$BASE/v1/lots/$SN_ID/bids" -H 'content-type: application/json' \
  -d '{"bidder":"carol","amountCents":100}')
SN_NEW=$(printf '%s' "$SN_BID" | jq -r .lot.endsAt)
SN_EXT=$(printf '%s' "$SN_BID" | jq -r .lot.extensions)
[ "$((SN_NEW - SN_END))" = "120" ] || fail "anti-sniping moved the end by $((SN_NEW - SN_END)), expected 120"
[ "$SN_EXT" = "1" ] || fail "extension counter is $SN_EXT, expected 1"
say "anti-sniping: end moved +120 s, extensions=1"

# 4. Closing tick, unsold case: the bid is under the reserve.
UN=$(curl -fsS -X POST "$BASE/v1/lots" -H 'content-type: application/json' \
  -d '{"title":"Unsold radio","seller":"solo","sellerEmail":"solo@arcod.test","startCents":100,"reserveCents":1000,"durationSec":3600}')
UN_ID=$(printf '%s' "$UN" | jq -r .id)
curl -fsS -X POST "$BASE/v1/lots/$UN_ID/bids" -H 'content-type: application/json' \
  -d '{"bidder":"eve","amountCents":500}' >/dev/null
curl -fsS -X POST "$BASE/v1/dev/lots/$UN_ID/expire" >/dev/null
CLOSED=$(curl -fsS -X POST "$BASE/v1/admin/close" | jq -r .closed)
[ "$CLOSED" -ge 1 ] || fail "closing tick closed nothing"
for _ in $(seq 1 40); do
  STATE=$(curl -fsS "$BASE/v1/lots/$UN_ID" | jq -r .lot.state)
  [ "$STATE" = "unsold" ] && break
  sleep 0.5
done
[ "$STATE" = "unsold" ] || fail "lot under the reserve stayed $STATE"
[ "$(curl -fsS "$BASE/v1/lots/$UN_ID" | jq -r '.bids[0].state')" = "lost" ] || fail "losing bid was not marked lost"
say "close: unsold, bid marked lost"

# 5. Closing tick, sold case: reserve met, the consumer mails both sides.
SOLD=$(curl -fsS -X POST "$BASE/v1/lots" -H 'content-type: application/json' \
  -d '{"title":"Desk lamp","seller":"sam","sellerEmail":"sam@arcod.test","startCents":100,"reserveCents":100,"durationSec":3600}')
SOLD_ID=$(printf '%s' "$SOLD" | jq -r .id)
curl -fsS -X POST "$BASE/v1/lots/$SOLD_ID/bids" -H 'content-type: application/json' \
  -d '{"bidder":"carol","amountCents":200}' >/dev/null
curl -fsS -X POST "$BASE/v1/dev/lots/$SOLD_ID/expire" >/dev/null
curl -fsS -X POST "$BASE/v1/admin/close" >/dev/null
for _ in $(seq 1 80); do
  MAILS=$(curl -fsS "$MAIL/api/v1/messages" | jq -r .total)
  [ "$MAILS" -ge 3 ] && break
  sleep 0.5
done
SOLD_STATE=$(curl -fsS "$BASE/v1/lots/$SOLD_ID" | jq -r .lot.state)
[ "$SOLD_STATE" = "sold" ] || fail "lot above the reserve is $SOLD_STATE"
[ "$MAILS" = "3" ] || fail "expected 3 mails (unsold seller, sold seller, winner), got $MAILS"
curl -fsS "$MAIL/api/v1/messages" | jq -e '[.messages[].to] | sort == ["sam@arcod.test","solo@arcod.test","winner@arcod.test"]' >/dev/null \
  || fail "mail recipients are wrong"
say "close: sold, consumer mailed seller + winner (3 messages total)"

# 6. Stats: money in cents, one aggregate for the volume.
STATS=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | jq -r .closedLots)" = "2" ] || fail "closedLots is wrong: $STATS"
[ "$(printf '%s' "$STATS" | jq -r .bidVolume)" = "5300" ] || fail "bidVolume is wrong: $STATS"
[ "$(printf '%s' "$STATS" | jq -r .notifications)" = "3" ] || fail "notifications counter is wrong: $STATS"
say "stats: closedLots=2, bidVolume=5300, notifications=3"

# 7. A second tick is a no-op: no new mail, no new rows.
CLOSED=$(curl -fsS -X POST "$BASE/v1/admin/close" | jq -r .closed)
[ "$CLOSED" = "0" ] || fail "second tick closed $CLOSED lots"
sleep 1
[ "$(curl -fsS "$MAIL/api/v1/messages" | jq -r .total)" = "3" ] || fail "second tick sent mail"
[ "$(curl -fsS "$BASE/v1/stats" | jq -r .notifications)" = "3" ] || fail "second tick added notifications"
say "idempotency: second tick closed 0, sent 0"

# 8. 404s.
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/lots/00000000-0000-0000-0000-000000000000")
[ "$CODE" = "404" ] || fail "unknown lot should be 404, got $CODE"
say "404: unknown lot"

echo "PASS"
