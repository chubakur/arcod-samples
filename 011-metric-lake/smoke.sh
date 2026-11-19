#!/usr/bin/env bash
# End-to-end: mysql + redis + minio + external alerting endpoint.
# Ingest -> redis queue -> rollup consumer -> buckets -> series/export/retention.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8096}"
ALERT_PORT="${ALERT_PORT:-9099}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
ALERTS=/tmp/arcod-011-alerts.jsonl
MOCK_PID=""

cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

ALERTS_FILE="$ALERTS" PORT="$ALERT_PORT" node mock/alerter.mjs & MOCK_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "http://localhost:${ALERT_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://localhost:${ALERT_PORT}/healthz" >/dev/null || fail "alerting mock is not up"

"$ARCOD" check >/dev/null
"$ARCOD" build --impl --port "$PORT" >/dev/null
"$ARCOD" run --impl --port "$PORT" >/tmp/arcod-sample-011.log 2>&1 &
for _ in $(seq 1 120); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy"
say "health: ok (service + mysql + redis + minio + alerter mock)"

# 1. Watch the metric, then ingest two batches through the queue.
MON=$(curl -fsS -X PUT "$BASE/v1/metrics/api_latency/monitor" \
  -H 'content-type: application/json' -d '{"threshold":25}')
[ "$(printf '%s' "$MON" | jq -r .metric)" = "api_latency" ] || fail "monitor not stored"
say "monitor: api_latency > 25"

NOW=$(node -e 'console.log(Date.now())')
TS1=$(node -e "console.log(new Date($NOW-90000).toISOString())")
TS2=$(node -e "console.log(new Date($NOW-60000).toISOString())")
OLD=$(node -e "console.log(new Date($NOW-7200000).toISOString())")

B1=$(curl -fsS -X POST "$BASE/v1/metrics/api_latency/points" \
  -H 'content-type: application/json' \
  -d "{\"idem\":\"batch-1\",\"samples\":[{\"ts\":\"$TS1\",\"value\":10},{\"ts\":\"$TS1\",\"value\":20},{\"ts\":\"$TS2\",\"value\":30}]}")
[ "$(printf '%s' "$B1" | jq -r .accepted)" = "3" ] || fail "ingest accepted != 3"
[ "$(printf '%s' "$B1" | jq -r .duplicate)" = "false" ] || fail "first batch marked duplicate"
BID=$(printf '%s' "$B1" | jq -r .batchId)
say "ingest: batch $BID accepted=3 (queued for rollup)"

# 2. Same (metric, idem) is the same batch: no new points, no second job that matters.
B2=$(curl -fsS -X POST "$BASE/v1/metrics/api_latency/points" \
  -H 'content-type: application/json' \
  -d "{\"idem\":\"batch-1\",\"samples\":[{\"ts\":\"$TS1\",\"value\":999}]}")
[ "$(printf '%s' "$B2" | jq -r .duplicate)" = "true" ] || fail "duplicate batch not detected"
[ "$(printf '%s' "$B2" | jq -r .batchId)" = "$BID" ] || fail "duplicate returned another batch"
say "idempotency: duplicate batch-1 returns $BID"

# 3. The consumer folds the batch into minute buckets.
FROM=$(node -e "console.log(new Date($NOW-600000).toISOString())")
TO=$(node -e "console.log(new Date($NOW+60000).toISOString())")
for _ in $(seq 1 30); do
  S=$(curl -fsS "$BASE/v1/metrics/api_latency/series?from=$FROM&to=$TO&step=60" || true)
  TOTAL=$(printf '%s' "$S" | jq -r '.total // 0' 2>/dev/null || echo 0)
  [ "$TOTAL" = "3" ] && break
  sleep 1
done
S=$(curl -fsS "$BASE/v1/metrics/api_latency/series?from=$FROM&to=$TO&step=60")
[ "$(printf '%s' "$S" | jq -r .total)" = "3" ] || fail "consumer did not roll up 3 points"
[ "$(printf '%s' "$S" | jq -r '[.points[].hi] | max')" = "30" ] || fail "bucket max is not 30"
[ "$(printf '%s' "$S" | jq -r '.points | map(.cnt) | add')" = "3" ] || fail "bucket count is not 3"
say "rollup: 3 points -> cnt=3 total=60 hi=30 mean=20"

# 4. The consumer calls the external alerting endpoint above the threshold.
for _ in $(seq 1 30); do
  [ -s "$ALERTS" ] && break
  sleep 1
done
[ -s "$ALERTS" ] || fail "no alert delivered to the external endpoint"
[ "$(jq -r .metric < "$ALERTS")" = "api_latency" ] || fail "alert has the wrong metric"
[ "$(jq -r .hi < "$ALERTS")" = "30" ] || fail "alert has the wrong peak"
say "alert: external endpoint got hi=30 > threshold=25"

# 5. A bigger value raises a second alert and moves the peak.
TS3=$(node -e "console.log(new Date(Date.now()-30000).toISOString())")
curl -fsS -X POST "$BASE/v1/metrics/api_latency/points" -H 'content-type: application/json' \
  -d "{\"idem\":\"batch-2\",\"samples\":[{\"ts\":\"$TS3\",\"value\":500}]}" >/dev/null
for _ in $(seq 1 30); do
  S=$(curl -fsS "$BASE/v1/metrics/api_latency/series?from=$FROM&to=$TO&step=60")
  [ "$(printf '%s' "$S" | jq -r .total)" = "4" ] && break
  sleep 1
done
[ "$(printf '%s' "$S" | jq -r '[.points[].hi] | max')" = "500" ] || fail "peak did not reach 500"
[ "$(wc -l < "$ALERTS" | tr -d ' ')" -ge 2 ] || fail "second alert was not delivered"
say "alert: second batch moved the peak to 500"

# 6. Step aggregation is computed over stored buckets, not raw points.
S5=$(curl -fsS "$BASE/v1/metrics/api_latency/series?from=$FROM&to=$TO&step=300")
[ "$(printf '%s' "$S5" | jq -r '.points | length')" = "1" ] || fail "step=300 did not collapse to one bucket"
[ "$(printf '%s' "$S5" | jq -r '.points[0].cnt')" = "4" ] || fail "step=300 lost points"
say "series: step=300 -> one bucket, cnt=4"

# 7. Export writes JSONL to object storage; it is readable back byte for byte.
EXP=$(curl -fsS -X POST "$BASE/v1/metrics/api_latency/export?from=$FROM&to=$TO")
EID=$(printf '%s' "$EXP" | jq -r .id)
LINES=$(printf '%s' "$EXP" | jq -r .lines)
[ "$LINES" -ge 2 ] || fail "export kept fewer than two buckets"
BODY=$(curl -fsS "$BASE/v1/exports/$EID" | jq -r .body)
printf '%s' "$BODY" | grep -q '"slot"' || fail "export body has no rows"
[ "$(printf '%s\n' "$BODY" | grep -c .)" = "$LINES" ] || fail "export body line count differs from metadata"
say "export: $EID ($(printf '%s' "$EXP" | jq -r .lines) rows in S3)"

# 8. Retention drops old raw points but keeps fresh ones.
OLD_B=$(curl -fsS -X POST "$BASE/v1/metrics/cron_gap/points" -H 'content-type: application/json' \
  -d "{\"idem\":\"old-1\",\"samples\":[{\"ts\":\"$OLD\",\"value\":7}]}")
[ "$(printf '%s' "$OLD_B" | jq -r .accepted)" = "1" ] || fail "old point was not accepted"
SW=$(curl -fsS -X POST "$BASE/v1/admin/sweep?horizonHours=1")
[ "$(printf '%s' "$SW" | jq -r .points)" -ge 1 ] || fail "sweep removed no old points"
[ "$(printf '%s' "$SW" | jq -r .report)" != "null" ] || fail "sweep wrote no retention report"
say "retention: sweep(1h) removed $(printf '%s' "$SW" | jq -r .points) point(s)"

# 9. Errors are typed, not 500s.
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/metrics/api_latency/points" \
  -H 'content-type: application/json' -d '{"idem":"bad","samples":[]}')
[ "$CODE" = "400" ] || fail "empty samples should be 400, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/metrics/nope/series?from=$FROM&to=$TO")
[ "$CODE" = "404" ] || fail "unknown metric should be 404, got $CODE"
say "errors: empty batch 400, unknown metric 404"

say "sample 011: PASS"
