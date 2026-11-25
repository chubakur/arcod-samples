#!/usr/bin/env bash
# 040-feature-store: feature definitions, event ingestion, online/offline
# reads, point-in-time exports, profile enrichment, dead letter and replay.
# Builds with the arcod under test, starts mysql + redis + s3 + a profile
# service on the host, then checks every path over HTTP. Ends with PASS.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8097}"
MOCK_PORT="${MOCK_PORT:-9098}"
BASE="http://localhost:${PORT}"
MOCK="http://localhost:${MOCK_PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-040.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
arcod_run() { $ARCOD "$@"; }

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
rm -f /tmp/arcod-040-profiles.log

MOCK_PORT="$MOCK_PORT" PROFILES_LOG=/tmp/arcod-040-profiles.log node mock/profiles.mjs >/tmp/arcod-040-mock.out 2>&1 &
MOCK_PID=$!

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
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see $LOG)"
say "health: ok (service + mysql + redis + s3 + profile mock)"

say "features"
F1=$(curl -fsS -X POST "$BASE/v1/features" -H 'content-type: application/json' \
  -d '{"name":"txn_count_7d","dtype":"int","description":"transactions in 7 days","ttlSeconds":3600}')
[ "$(printf '%s' "$F1" | jq -r .version)" = "1" ] || fail "new feature is not v1: $F1"
curl -fsS -X POST "$BASE/v1/features" -H 'content-type: application/json' \
  -d '{"name":"spend_usd","dtype":"float","description":"spend in usd","ttlSeconds":86400}' >/dev/null
curl -fsS -X POST "$BASE/v1/features" -H 'content-type: application/json' \
  -d '{"name":"tier","dtype":"string","description":"plan tier","ttlSeconds":86400}' >/dev/null
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/features" -H 'content-type: application/json' \
  -d '{"name":"txn_count_7d","dtype":"int","description":"again","ttlSeconds":3600}')
[ "$DUP" = "409" ] || fail "duplicate feature answered $DUP, want 409"
BADD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/features" -H 'content-type: application/json' \
  -d '{"name":"bad_dtype","dtype":"matrix","description":"x","ttlSeconds":3600}')
[ "$BADD" = "400" ] || fail "unknown dtype answered $BADD, want 400"
LIST=$(curl -fsS "$BASE/v1/features")
[ "$(printf '%s' "$LIST" | jq 'length')" = "3" ] || fail "expected 3 features: $LIST"
say "features: three definitions, duplicate 409, bad dtype 400"

say "events"
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"e-1","value":"3","at":"2026-11-19T10:00:00Z"}' >/dev/null
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"e-1","value":"7","at":"2026-11-20T10:00:00Z"}' >/dev/null
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"e-2","value":"2","at":"2026-11-20T12:00:00Z"}' >/dev/null
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"spend_usd","entityId":"e-1","value":"100.50","at":"2026-11-20T11:00:00Z"}' >/dev/null
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"tier","entityId":"e-1","value":"gold","at":"2026-11-20T09:00:00Z"}' >/dev/null
NOF=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"missing","entityId":"e-1","value":"1","at":"2026-11-20T09:00:00Z"}')
[ "$NOF" = "404" ] || fail "unknown feature ingest answered $NOF, want 404"
BADV=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"e-1","value":"lots","at":"2026-11-20T09:00:00Z"}')
[ "$BADV" = "400" ] || fail "non-int value answered $BADV, want 400"

for _ in $(seq 1 40); do
  PENDING=$(curl -fsS "$BASE/v1/stats" | jq -r .pending)
  [ "$PENDING" = "0" ] && break
  sleep 1
done
[ "$PENDING" = "0" ] || fail "materialiser left $PENDING events pending"
say "events: 5 accepted, unknown feature 404, non-int 400, materialiser caught up"

say "online"
ON=$(curl -fsS "$BASE/v1/online/txn_count_7d/e-1")
[ "$(printf '%s' "$ON" | jq -r .value)" = "7" ] || fail "online value is not 7: $ON"
[ "$(printf '%s' "$ON" | jq -r .stale)" = "true" ] || fail "old value should be stale: $ON"
[ "$(printf '%s' "$ON" | jq -r .version)" = "1" ] || fail "online version is not 1: $ON"

# A late, older event must not roll the online value back.
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"e-1","value":"5","at":"2026-11-19T12:00:00Z"}' >/dev/null
sleep 3
ON2=$(curl -fsS "$BASE/v1/online/txn_count_7d/e-1")
[ "$(printf '%s' "$ON2" | jq -r .value)" = "7" ] || fail "older event rolled the online value back: $ON2"
say "online: value 7, stale flagged, older event ignored"

say "versioning"
curl -fsS -X POST "$BASE/v1/features/txn_count_7d/versions" -H 'content-type: application/json' \
  -d '{"description":"30 day window"}' >/dev/null
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"e-1","value":"9","at":"2026-11-21T09:00:00Z"}' >/dev/null
sleep 3
ON3=$(curl -fsS "$BASE/v1/online/txn_count_7d/e-1")
[ "$(printf '%s' "$ON3" | jq -r .value)" = "9" ] || fail "new event did not land online: $ON3"
[ "$(printf '%s' "$ON3" | jq -r .version)" = "2" ] || fail "online version is not 2: $ON3"
OFF=$(curl -fsS "$BASE/v1/offline/txn_count_7d/e-1")
[ "$(printf '%s' "$OFF" | jq 'length')" = "4" ] || fail "expected 4 offline points: $OFF"
say "versioning: v2 events carry v2; offline keeps all four points"

say "export"
EX=$(curl -fsS -X POST "$BASE/v1/exports" -H 'content-type: application/json' \
  -d '{"features":["txn_count_7d","spend_usd"],"fromAt":"2026-11-01T00:00:00Z","toAt":"2026-11-21T08:00:00Z"}')
XID=$(printf '%s' "$EX" | jq -r .id)
[ -n "$XID" ] && [ "$XID" != "null" ] || fail "export was not created: $EX"
for _ in $(seq 1 40); do
  ST=$(curl -fsS "$BASE/v1/exports/$XID")
  [ "$(printf '%s' "$ST" | jq -r .status)" = "done" ] && break
  sleep 1
done
[ "$(printf '%s' "$ST" | jq -r .status)" = "done" ] || fail "export did not finish: $ST"
[ "$(printf '%s' "$ST" | jq -r .rows)" = "3" ] || fail "expected 3 rows in export: $ST"
FILE=$(curl -fsS "$BASE/v1/exports/$XID/file")
printf '%s' "$FILE" | jq -r .content | awk 'NF' > /tmp/arcod-040-export.csv
if [ "$(wc -l < /tmp/arcod-040-export.csv | tr -d ' ')" != "4" ]; then
  fail "CSV should have header + 3 rows: $(cat /tmp/arcod-040-export.csv)"
fi
grep -q 'enterprise' /tmp/arcod-040-export.csv || fail "profile attributes missing from CSV"
grep -q 'e-2' /tmp/arcod-040-export.csv || fail "second entity missing from CSV"
if grep -q '2026-11-21T09' /tmp/arcod-040-export.csv; then fail "export leaked a value after the window end"; fi
say "export: 3 rows, point-in-time cut, profile enrichment in S3"

say "dead letter"
curl -fsS -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"feature":"txn_count_7d","entityId":"fail-1","value":"1","at":"2026-11-20T10:00:00Z"}' >/dev/null
sleep 2
DX=$(curl -fsS -X POST "$BASE/v1/exports" -H 'content-type: application/json' \
  -d '{"features":["txn_count_7d"],"fromAt":"2026-11-01T00:00:00Z","toAt":"2026-11-22T00:00:00Z"}')
DID=$(printf '%s' "$DX" | jq -r .id)
for _ in $(seq 1 40); do
  DEAD=$(curl -fsS "$BASE/v1/dead" | jq '.items | length')
  [ "$DEAD" != "0" ] && break
  sleep 1
done
[ "$DEAD" != "0" ] || fail "failed export never reached the dead letter"
DST=$(curl -fsS "$BASE/v1/exports/$DID")
[ "$(printf '%s' "$DST" | jq -r .status)" = "failed" ] || fail "failed export is not marked failed: $DST"
curl -fsS "$MOCK/heal" >/dev/null
RP=$(curl -fsS -X POST "$BASE/v1/dead/replay")
[ "$(printf '%s' "$RP" | jq -r .replayed)" = "1" ] || fail "replay did not move the message: $RP"
for _ in $(seq 1 40); do
  DST=$(curl -fsS "$BASE/v1/exports/$DID")
  [ "$(printf '%s' "$DST" | jq -r .status)" = "done" ] && break
  sleep 1
done
[ "$(printf '%s' "$DST" | jq -r .status)" = "done" ] || fail "replayed export did not finish: $DST"
[ "$(curl -fsS "$BASE/v1/dead" | jq '.items | length')" = "0" ] || fail "dead letter not empty after replay"
say "dead letter: failure recorded, replay after heal completed the export"

say "stats"
STATS=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | jq -r .features)" = "3" ] || fail "stats features: $STATS"
[ "$(printf '%s' "$STATS" | jq -r .done)" = "2" ] || fail "stats done: $STATS"
[ "$(printf '%s' "$STATS" | jq -r .pending)" = "0" ] || fail "stats pending: $STATS"
say "stats: 3 features, 2 exports done, nothing pending"

say "PASS"
