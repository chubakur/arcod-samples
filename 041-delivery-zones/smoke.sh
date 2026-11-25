#!/usr/bin/env bash
# 041-delivery-zones: polygons and tariffs in Postgres, a Redis-backed queue,
# zone snapshots in S3 and a host geocoder. Checks zone CRUD, point-in-polygon
# quoting, kv caching, the reindex consumer and S3 snapshot output.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8093}"
GEO_PORT="${GEO_PORT:-9096}"
BASE="http://localhost:${PORT}"
GEO="http://localhost:${GEO_PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-041.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
arcod_run() { $ARCOD "$@"; }

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

say "mock geocoder"
GEO_PORT="$GEO_PORT" node mock/geocoder.mjs >/tmp/arcod-041-geo.log 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do
  curl -fsS "$GEO/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$GEO/healthz" >/dev/null || fail "geocoder mock did not start"

say "check"
arcod_run check >/dev/null

say "build"
arcod_run build --impl --port "$PORT" >/dev/null

say "run"
arcod_run run --impl --port "$PORT" >"$LOG" 2>&1 &
for _ in $(seq 1 90); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -40 "$LOG"; fail "service did not become healthy"; }

say "zone: create"
ZONE=$(curl -fsS -X POST "$BASE/v1/zones" -H 'content-type: application/json' \
  -d '{"name":"center","polygon":"[[37.50,55.70],[37.70,55.70],[37.70,55.80],[37.50,55.80]]","basePrice":100,"perKm":20}')
ZID=$(printf '%s' "$ZONE" | jq -r .id)
[ "$(printf '%s' "$ZONE" | jq -r .name)" = "center" ] || fail "zone name"
[ "$(printf '%s' "$ZONE" | jq -r '.active')" = "true" ] || fail "zone active"
say "zone $ZID"

say "zone: duplicate name 409"
CODE=$(curl -sS -o /tmp/arcod-041-dup.json -w '%{http_code}' -X POST "$BASE/v1/zones" \
  -H 'content-type: application/json' \
  -d '{"name":"center","polygon":"[[37.0,55.0],[37.1,55.0],[37.1,55.1]]","basePrice":1,"perKm":1}')
[ "$CODE" = "409" ] || fail "duplicate zone expected 409, got $CODE"

say "zone: bad polygon 400"
CODE=$(curl -sS -o /tmp/arcod-041-bad.json -w '%{http_code}' -X POST "$BASE/v1/zones" \
  -H 'content-type: application/json' \
  -d '{"name":"broken","polygon":"[[1,2]]","basePrice":1,"perKm":1}')
[ "$CODE" = "400" ] || fail "bad polygon expected 400, got $CODE"

say "quote: inside polygon"
Q1=$(curl -fsS -X POST "$BASE/v1/quotes" -H 'content-type: application/json' \
  -d '{"lat":55.75,"lng":37.60,"distanceKm":5}')
QID=$(printf '%s' "$Q1" | jq -r .id)
[ "$(printf '%s' "$Q1" | jq -r .price)" = "200" ] || fail "price expected 200"
[ "$(printf '%s' "$Q1" | jq -r .zoneId)" = "$ZID" ] || fail "zone resolution"
ADDR=$(printf '%s' "$Q1" | jq -r .address)
case "$ADDR" in Mock*) ;; *) fail "geocoder address not used: $ADDR" ;; esac
say "quote $QID price 200, address $ADDR"

say "quote: cached zone on repeat"
Q2=$(curl -fsS -X POST "$BASE/v1/quotes" -H 'content-type: application/json' \
  -d '{"lat":55.75,"lng":37.60,"distanceKm":1}')
[ "$(printf '%s' "$Q2" | jq -r .cachedZone)" = "true" ] || fail "second quote did not hit the kv cache"
[ "$(printf '%s' "$Q2" | jq -r .price)" = "120" ] || fail "second price expected 120"

say "quote: outside polygon 404"
CODE=$(curl -sS -o /tmp/arcod-041-out.json -w '%{http_code}' -X POST "$BASE/v1/quotes" \
  -H 'content-type: application/json' -d '{"lat":10.0,"lng":10.0,"distanceKm":1}')
[ "$CODE" = "404" ] || fail "outside quote expected 404, got $CODE"

say "quote: read back"
GOT=$(curl -fsS "$BASE/v1/quotes/$QID")
[ "$(printf '%s' "$GOT" | jq -r .id)" = "$QID" ] || fail "getQuote id"

say "consumer: S3 snapshot appears"
SNAP=""
for _ in $(seq 1 30); do
  CODE=$(curl -sS -o /tmp/arcod-041-snap.json -w '%{http_code}' "$BASE/v1/zones/$ZID/snapshot" || true)
  if [ "$CODE" = "200" ]; then SNAP=$(cat /tmp/arcod-041-snap.json); break; fi
  sleep 1
done
[ -n "$SNAP" ] || { tail -40 "$LOG"; fail "reindex consumer did not write the snapshot"; }
[ "$(printf '%s' "$SNAP" | jq -r .key)" = "zones/$ZID.json" ] || fail "snapshot key"
printf '%s' "$SNAP" | jq -r .content | jq -e '.name == "center"' >/dev/null || fail "snapshot payload"

say "zones: list"
LIST=$(curl -fsS "$BASE/v1/zones")
[ "$(printf '%s' "$LIST" | jq 'length')" = "1" ] || fail "zone list expected 1"

say "stats"
ST=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$ST" | jq -r .zones)" = "1" ] || fail "stats zones"
[ "$(printf '%s' "$ST" | jq -r .quotes)" = "2" ] || fail "stats quotes"
[ "$(printf '%s' "$ST" | jq -r .activeZones)" = "1" ] || fail "stats active"

say "PASS: delivery zones, geocoder, kv cache, queue consumer and S3 snapshot"
