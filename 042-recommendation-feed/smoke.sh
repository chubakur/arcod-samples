#!/usr/bin/env bash
# 042-recommendation-feed: catalogue in Postgres, interactions in Postgres,
# an item-item model built by two queue consumers and stored in S3, the
# pointer in kv, feeds read from the snapshot.
# Checks: catalogue, idempotent ingest, the recompute consumer, the snapshot
# consumer, S3 output, seen-filtering, co-occurrence ordering, cold start.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8094}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-042.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:--}"; }

cleanup() {
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
for _ in $(seq 1 120); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -40 "$LOG"; fail "service did not start"; }

add_item() {
  curl -sS -X POST "$BASE/v1/items" -H 'content-type: application/json' \
    -d "{\"title\":\"$1\",\"category\":\"$2\",\"price\":$3}"
}

say "catalogue: five items"
KB=$(add_item "Mechanical Keyboard" input 12000); KB_ID=$(printf '%s' "$KB" | J .id)
HUB=$(add_item "USB-C Hub" dock 9000);       HUB_ID=$(printf '%s' "$HUB" | J .id)
CAM=$(add_item "Webcam" video 7000);         CAM_ID=$(printf '%s' "$CAM" | J .id)
ARM=$(add_item "Monitor Arm" desk 6500);     ARM_ID=$(printf '%s' "$ARM" | J .id)
LAM=$(add_item "Desk Lamp" desk 3500);       LAM_ID=$(printf '%s' "$LAM" | J .id)
[ -n "$KB_ID" ] && [ "$KB_ID" != "null" ] || fail "item id"

say "catalogue: duplicate title is 409"
CODE=$(curl -sS -o /tmp/arcod-042-dup.json -w '%{http_code}' -X POST "$BASE/v1/items" \
  -H 'content-type: application/json' -d '{"title":"Mechanical Keyboard","category":"input","price":1}')
[ "$CODE" = "409" ] || fail "duplicate title: $CODE"

say "ingest: five users, three kinds"
track() {
  curl -sS -o /tmp/arcod-042-event.json -w '%{http_code}' -X POST "$BASE/v1/events" \
    -H 'content-type: application/json' \
    -d "{\"clientEventId\":\"$1\",\"userId\":\"$2\",\"itemId\":\"$3\",\"kind\":\"$4\"}"
}
[ "$(track e-a1 alice "$KB_ID" view)" = "201" ] || fail "alice view"
[ "$(track e-a2 alice "$HUB_ID" buy)" = "201" ] || fail "alice buy"
[ "$(track e-b1 bob "$KB_ID" view)" = "201" ] || fail "bob view"
[ "$(track e-b2 bob "$HUB_ID" buy)" = "201" ] || fail "bob buy"
[ "$(track e-b3 bob "$CAM_ID" buy)" = "201" ] || fail "bob cam"
[ "$(track e-c1 carol "$KB_ID" view)" = "201" ] || fail "carol view"
[ "$(track e-c2 carol "$ARM_ID" cart)" = "201" ] || fail "carol cart"
[ "$(track e-d1 dave "$KB_ID" view)" = "201" ] || fail "dave view"

say "ingest: retry with the same clientEventId is idempotent"
FIRST_ID=$(J .id /tmp/arcod-042-event.json)
CODE=$(curl -sS -o /tmp/arcod-042-event2.json -w '%{http_code}' -X POST "$BASE/v1/events" \
  -H 'content-type: application/json' \
  -d "{\"clientEventId\":\"e-d1\",\"userId\":\"dave\",\"itemId\":\"$KB_ID\",\"kind\":\"view\"}")
# Arcod answers 201 for every successful POST op; the row id is the witness.
[ "$CODE" = "201" ] || fail "retry status $CODE"
[ "$(J .id /tmp/arcod-042-event2.json)" = "$FIRST_ID" ] || fail "retry returned a different row"

say "ingest: unknown item is 400"
CODE=$(track e-x1 zoe 00000000-0000-4000-8000-000000000000 view)
[ "$CODE" = "400" ] || fail "unknown item: $CODE"

say "consumer 1: per-user pair evidence appears"
TOUCHES=0
for _ in $(seq 1 40); do
  ST=$(curl -fsS "$BASE/v1/stats")
  TOUCHES=$(printf '%s' "$ST" | J .touches)
  [ "$TOUCHES" -ge 4 ] && break
  sleep 0.5
done
[ "$TOUCHES" -ge 4 ] || fail "recompute consumer wrote $TOUCHES touches"

say "consumer 2: rebuild publishes, job writes S3 and flips the pointer"
curl -fsS -X POST "$BASE/v1/model/rebuild" >/dev/null
VERSION=0
for _ in $(seq 1 40); do
  M=$(curl -fsS "$BASE/v1/model")
  VERSION=$(printf '%s' "$M" | J .version)
  [ "$VERSION" -ge 1 ] && break
  sleep 0.5
done
[ "$VERSION" -ge 1 ] || fail "model version never appeared"
[ "$(printf '%s' "$M" | J .items)" = "5" ] || fail "model items"
[ "$(printf '%s' "$M" | J .key)" = "models/v$VERSION.json" ] || fail "model key"

say "snapshot: the S3 object is readable and matches the pointer"
SN=$(curl -fsS "$BASE/v1/model/snapshot")
[ "$(printf '%s' "$SN" | J .version)" = "$VERSION" ] || fail "snapshot version"
[ "$(printf '%s' "$SN" | J '.content | contains("neighbours")')" = "true" ] || fail "snapshot body"
[ "$(printf '%s' "$SN" | jq -r '.bytes')" -gt 50 ] || fail "snapshot size"

say "feed: dave saw the keyboard, so co-occurring items come first"
FEED=$(curl -fsS "$BASE/v1/feed/dave?limit=10")
COUNT=$(printf '%s' "$FEED" | jq 'length')
[ "$COUNT" = "3" ] || fail "feed size $COUNT"
printf '%s' "$FEED" | jq -e --arg kb "$KB_ID" 'all(.itemId != $kb)' >/dev/null || fail "seen keyboard leaked"
printf '%s' "$FEED" | jq -e --arg hub "$HUB_ID" --arg arm "$ARM_ID" --arg cam "$CAM_ID" \
  '([.[] | select(.reason == "co-occur") | .itemId] | sort) == ([$hub, $arm, $cam] | sort)' >/dev/null \
  || fail "co-occur candidates"
printf '%s' "$FEED" | jq -e --arg hub "$HUB_ID" 'map(select(.itemId == $hub))[0].score == 2' >/dev/null || fail "hub score"
[ "$(printf '%s' "$FEED" | jq -r '.[0].reason')" = "co-occur" ] || fail "top reason"

say "feed: a cold user gets popularity, weighted by kind"
COLD=$(curl -fsS "$BASE/v1/feed/erin?limit=3")
[ "$(printf '%s' "$COLD" | jq 'length')" = "3" ] || fail "cold feed size"
[ "$(printf '%s' "$COLD" | jq -r '.[0].itemId')" = "$HUB_ID" ] || fail "cold top is not the best seller"
[ "$(printf '%s' "$COLD" | jq -r '.[0].reason')" = "popular" ] || fail "cold reason"

say "feed: limit is enforced"
[ "$(curl -fsS "$BASE/v1/feed/erin?limit=1" | jq 'length')" = "1" ] || fail "limit"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/feed/erin?limit=99")
[ "$CODE" = "400" ] || fail "limit 99: $CODE"

say "stats"
ST=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$ST" | J .items)" = "5" ] || fail "stats items"
[ "$(printf '%s' "$ST" | J .events)" = "8" ] || fail "stats events"
[ "$(printf '%s' "$ST" | J .modelVersion)" -ge 1 ] || fail "stats model"

say "PASS: catalogue, idempotent ingest, pair consumer, S3 snapshot, co-occurrence feed, cold start"
