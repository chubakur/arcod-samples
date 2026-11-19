#!/usr/bin/env bash
# End-to-end: mysql + minio + rabbitmq + service, queue consumer, retry, errors.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8094}"
BASE="http://localhost:$PORT"
COMPOSE=".arcod/build/docker-compose.yml"

cleanup() {
  docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }

arcod build --impl --port "$PORT" >/dev/null
docker compose -f "$COMPOSE" up -d --wait >/dev/null 2>&1 || docker compose -f "$COMPOSE" up -d >/dev/null
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null
say "health: ok (service + mysql + minio + rabbitmq)"

REPORT=$(curl -fsS -X POST "$BASE/v1/reports" -H 'content-type: application/json' \
  -d '{"name":"daily.txt","body":"hello world\nsecond line here"}')
ID=$(printf '%s' "$REPORT" | jq -r .id)
[ "$(printf '%s' "$REPORT" | jq -r .status)" = "queued" ]
say "submit: $ID queued"

for _ in $(seq 1 40); do
  STATUS=$(curl -fsS "$BASE/v1/reports/$ID" | jq -r .status)
  [ "$STATUS" = "done" ] && break
  sleep 0.5
done
DONE=$(curl -fsS "$BASE/v1/reports/$ID")
[ "$(printf '%s' "$DONE" | jq -r .status)" = "done" ]
[ "$(printf '%s' "$DONE" | jq -r .lines)" = "2" ]
[ "$(printf '%s' "$DONE" | jq -r .words)" = "5" ]
say "consumer: done, lines=2 words=5"

RETRY=$(curl -fsS -X POST "$BASE/v1/reports/$ID/retry")
[ "$(printf '%s' "$RETRY" | jq -r .status)" = "queued" ]
for _ in $(seq 1 40); do
  STATUS=$(curl -fsS "$BASE/v1/reports/$ID" | jq -r .status)
  [ "$STATUS" = "done" ] && break
  sleep 0.5
done
[ "$STATUS" = "done" ]
say "retry: re-queued and processed again"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/reports/00000000-0000-0000-0000-000000000000")
[ "$CODE" = "404" ]
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/reports" \
  -H 'content-type: application/json' -d '{"name":"","body":"x"}')
[ "$CODE" = "400" ]
say "errors: unknown 404, empty name 400"

say "sample 009: PASS"
