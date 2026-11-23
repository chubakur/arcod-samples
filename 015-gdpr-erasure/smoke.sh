#!/usr/bin/env bash
# End-to-end: mysql + redis(queue) + minio + external compliance gateway.
# Seed PII for two subjects -> one erasure request -> consumer deletes the rows
# table by table, writes the manifest to S3, the gateway rejects the first
# certificate (retry) and accepts the second; the other subject stays intact.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8096}"
GATEWAY_PORT="${GATEWAY_PORT:-9097}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
GATEWAY_LOG=/tmp/arcod-015-gateway.jsonl
MOCK_PID=""
RUN_PID=""

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
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
rm -f "$GATEWAY_LOG"

PORT="$GATEWAY_PORT" FAIL_FIRST=1 GATEWAY_LOG="$GATEWAY_LOG" node mock/compliance.mjs >/tmp/arcod-015-mock.log 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  if curl -fsS "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.25
done
curl -fsS "http://localhost:${GATEWAY_PORT}/healthz" >/dev/null || fail "compliance mock is not up"

arcod_run check >/dev/null
arcod_run build --impl --port "$PORT" >/dev/null
arcod_run run --impl --port "$PORT" >/tmp/arcod-sample-015.log 2>&1 &
RUN_PID=$!
for _ in $(seq 1 150); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy"
say "health: ok (service + mysql + redis queue + minio + gateway mock)"

# 1. Demo PII: alice has 1 customer + 2 notes + 2 tickets, bob has 3 rows.
curl -fsS -X POST "$BASE/v1/dev/seed" | jq -e '.ok == true' >/dev/null || fail "seed"
ALICE=$(curl -fsS "$BASE/v1/subjects/alice@example.com")
[ "$(printf '%s' "$ALICE" | jq '[.remaining[].rows] | add')" = "5" ] || fail "alice should start with 5 rows"
BOB=$(curl -fsS "$BASE/v1/subjects/bob@example.com")
[ "$(printf '%s' "$BOB" | jq '[.remaining[].rows] | add')" = "3" ] || fail "bob should start with 3 rows"
say "seed: alice=5 rows, bob=3 rows"

# 2. One live request per subject; the second ask is a conflict, not a queue spam.
REQ=$(curl -fsS -X POST "$BASE/v1/requests" -H 'content-type: application/json' \
  -d '{"subjectEmail":"Alice@Example.com","reason":"demo erasure"}')
ID=$(printf '%s' "$REQ" | jq -r .id)
[ -n "$ID" ] && [ "$ID" != "null" ] || fail "create returned no id"
[ "$(printf '%s' "$REQ" | jq -r .subjectLabel)" = "a***@example.com" ] || fail "the address must be masked"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/requests" -H 'content-type: application/json' \
  -d '{"subjectEmail":"alice@example.com"}')
[ "$CODE" = "409" ] || fail "duplicate live request should be 409, got $CODE"
say "create: id=$ID, duplicate -> 409"

# 3. Two consumers: cascade, then certificate at the gateway. The first call is
# rejected on purpose, so a green result proves the retry really happened.
for _ in $(seq 1 60); do
  STATE=$(curl -fsS "$BASE/v1/requests/$ID" | jq -r .request.state)
  [ "$STATE" = "certified" ] && break
  [ "$STATE" = "failed" ] && fail "request failed"
  sleep 0.5
done
[ "$STATE" = "certified" ] || fail "request stayed in ${STATE:-unknown}"

VIEW=$(curl -fsS "$BASE/v1/requests/$ID")
[ "$(printf '%s' "$VIEW" | jq -r .request.rowsDeleted)" = "5" ] || fail "expected 5 deleted rows"
[ "$(printf '%s' "$VIEW" | jq '[.remaining[].rows] | add')" = "0" ] || fail "alice must have no rows left"
[ "$(printf '%s' "$VIEW" | jq -r .request.certificate)" != "null" ] || fail "no certificate"
say "erase: 5 rows deleted across 3 datasets, state=certified"

# 4. The other subject is untouched: a cascade that deletes everything is a bug.
BOB=$(curl -fsS "$BASE/v1/subjects/bob@example.com")
[ "$(printf '%s' "$BOB" | jq '[.remaining[].rows] | add')" = "3" ] || fail "bob was touched"
say "isolation: bob still has 3 rows"

# 5. Manifest in S3, served through the API, never from a public bucket.
CERT=$(curl -fsS "$BASE/v1/requests/$ID/certificate")
printf '%s' "$CERT" | jq -e --arg id "$ID" '.body | fromjson | .requestId == $id' >/dev/null || fail "manifest body"
printf '%s' "$CERT" | jq -e '.body | fromjson | [.datasets[].rows] | add == 5' >/dev/null || fail "manifest rows"
say "manifest: $(printf '%s' "$CERT" | jq -r .name) from S3"

# 6. Gateway saw exactly two calls: 503 then 200.
GW=$(wc -l < "$GATEWAY_LOG" | tr -d ' ')
[ "$GW" = "2" ] || fail "gateway calls: expected 2, got $GW"
[ "$(tail -1 "$GATEWAY_LOG" | jq -r .status)" = "200" ] || fail "last gateway call is not 200"
say "gateway: 503 then 200, certificate $(printf '%s' "$VIEW" | jq -r .request.certificate)"

# 7. Repeating the job does not rewrite the evidence.
curl -fsS -X POST "$BASE/v1/requests/$ID/retry" | jq -e '.ok == true and .queued == 0' >/dev/null || fail "retry on certified"
[ "$(wc -l < "$GATEWAY_LOG" | tr -d ' ')" = "2" ] || fail "a certified request called the gateway again"
curl -fsS -X POST "$BASE/v1/sweep" | jq -e '.ok == true' >/dev/null || fail "sweep"
say "idempotency: certified request stays put, sweep queues nothing"

# 8. Validation and 404s.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/requests" -H 'content-type: application/json' -d '{"subjectEmail":"nope"}')
[ "$CODE" = "400" ] || fail "bad email should be 400, got $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/requests/00000000-0000-0000-0000-000000000000")
[ "$CODE" = "404" ] || fail "unknown request should be 404, got $CODE"

STATS=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | jq -r .rowsErased)" = "5" ] || fail "stats rowsErased"
say "stats: $(printf '%s' "$STATS" | jq -c .)"

echo "PASS"
