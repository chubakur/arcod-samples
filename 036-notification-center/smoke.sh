#!/usr/bin/env bash
# End-to-end: mysql + redis queue + s3 + a mail gateway on the compose network.
# Template -> campaign -> fan-out consumer -> deliver consumer (one retry path
# into the dead letter) -> stats, CSV export to S3, idempotent second fan-out.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8094}"
MAIL_PORT="${MAIL_PORT:-9096}"
BASE="http://localhost:${PORT}"
MAIL="http://localhost:${MAIL_PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
RUN_PID=""
MAILER_NAME="arcod-036-mailer"

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
arcod_run run --impl --port "$PORT" >/tmp/arcod-sample-036.log 2>&1 &
RUN_PID=$!

for _ in $(seq 1 180); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see /tmp/arcod-sample-036.log)"
say "health: ok (service + mysql + redis queue + s3)"

# The mail gateway joins the same compose network under the name the spec
# binds. Its image is the service image, only the entrypoint changes.
IMAGE=$(grep -m1 'image: arcod/notification-center-service' .arcod/build/docker-compose.yml | awk '{print $2}')
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

# 1. Template, then the same code again: Conflict, not a second row.
CODE=$(curl -s -o /tmp/arcod-036-template.json -w '%{http_code}' -X POST "$BASE/v1/templates" \
  -H 'content-type: application/json' \
  -d '{"code":"launch","name":"Launch","subject":"Hello {{name}}","body":"Hi {{name}}, {{campaign}} starts now"}')
[ "$CODE" = "201" ] || fail "template create answered $CODE"
DUP=$(curl -s -o /tmp/arcod-036-dup.json -w '%{http_code}' -X POST "$BASE/v1/templates" \
  -H 'content-type: application/json' \
  -d '{"code":"launch","name":"Launch","subject":"x","body":"y"}')
[ "$DUP" = "409" ] || fail "duplicate template code answered $DUP, want 409"
say "template: created, duplicate code: 409"

# 2. Campaign: four addresses, one of them on a domain the gateway rejects.
CODE=$(curl -s -o /tmp/arcod-036-campaign.json -w '%{http_code}' -X POST "$BASE/v1/campaigns" \
  -H 'content-type: application/json' \
  -d '{"templateCode":"launch","name":"Spring launch","audience":[{"email":"alice@arcod.test","name":"Alice"},{"email":"bob@arcod.test","name":"Bob"},{"email":"carol@arcod.test","name":"Carol"},{"email":"bounce@bounce.test","name":"Bounce"}]}')
[ "$CODE" = "201" ] || fail "campaign create answered $CODE"
CID=$(jq -r .id /tmp/arcod-036-campaign.json)
[ "$CID" != "null" ] || fail "campaign has no id"
say "campaign: ${CID:0:8} accepted, fan-out is the consumer's job"

# 3. The consumers finish on their own: no tick, no admin call.
STATUS=""
for _ in $(seq 1 90); do
  VIEW=$(curl -fsS "$BASE/v1/campaigns/$CID")
  STATUS=$(echo "$VIEW" | jq -r .campaign.status)
  if [ "$STATUS" = "done" ]; then break; fi
  sleep 1
done
[ "$STATUS" = "done" ] || fail "campaign stuck in $STATUS"
echo "$VIEW" | jq -e '.total == 4 and .sent == 3 and .failed == 1 and .queued == 0' >/dev/null \
  || fail "counts are wrong: $(echo "$VIEW" | jq -c '{total,sent,failed,queued}')"
say "deliveries: 4 rows, 3 sent, 1 failed, 0 queued (consumer-driven)"

# 4. The gateway saw exactly the three accepted messages, personalised.
MAILS=$(curl -fsS "$MAIL/api/v1/messages")
[ "$(echo "$MAILS" | jq -r .total)" = "3" ] || fail "mail gateway saw $(echo "$MAILS" | jq -r .total) messages, want 3"
echo "$MAILS" | jq -e '[.messages[] | select(.text | contains("Spring launch starts now"))] | length == 3' >/dev/null \
  || fail "the campaign name was not rendered into every body"
echo "$MAILS" | jq -e '[.messages[] | select(.to == "alice@arcod.test" and (.text | contains("Hi Alice")))] | length == 1' >/dev/null \
  || fail "alice's message is not personalised"
say "mail: 3 personalised messages, the bounce address never accepted"

# 5. The failed address exhausted its retry budget: row and dead letter agree.
FAILED_ID=$(curl -fsS "$BASE/v1/campaigns/$CID/deliveries" | jq -r '.items[] | select(.status == "failed") | .id')
[ -n "$FAILED_ID" ] || fail "no failed delivery"
DEAD=$(curl -fsS "$BASE/v1/dead")
[ "$(echo "$DEAD" | jq -r .total)" = "1" ] || fail "dead letter has $(echo "$DEAD" | jq -r .total) messages, want 1"
echo "$DEAD" | jq -e --arg id "$FAILED_ID" '.ids | index($id)' >/dev/null \
  || fail "dead letter does not carry the failed delivery id"
say "retries: failed delivery ${FAILED_ID:0:8} is in the dead letter"

# 6. Analytics: the day row and the CSV in S3.
DAILY=$(curl -fsS "$BASE/v1/daily")
echo "$DAILY" | jq -e '.sent == 3 and .failed == 1' >/dev/null || fail "daily stats are $(echo "$DAILY" | jq -c '{sent,failed}')"
say "analytics: day row sent=3 failed=1"

REPORT=$(curl -fsS "$BASE/v1/campaigns/$CID/report")
[ "$(echo "$REPORT" | jq -r .rows)" = "4" ] || fail "report rows are $(echo "$REPORT" | jq -r .rows)"
[ "$(echo "$REPORT" | jq -r .key)" = "reports/$CID.csv" ] || fail "unexpected report key"
CSV=$(curl -fsS "$BASE/v1/campaigns/$CID/report.csv" | jq -r .body)
[ "$(echo "$CSV" | wc -l | tr -d ' ')" = "5" ] || fail "csv has $(echo "$CSV" | wc -l | tr -d ' ') lines, want 5"
echo "$CSV" | head -1 | grep -q '^email,name,status,attempts,error,sent_at$' || fail "csv header is wrong"
echo "$CSV" | grep -q 'bounce@bounce.test,Bounce,failed,3,' || fail "csv lost the failed delivery"
say "export: 4 rows in s3, csv readable back through the service"

# 7. A second fan-out for the same campaign changes nothing.
BEFORE=$(curl -fsS "$MAIL/api/v1/messages" | jq -r .total)
curl -fsS -X POST "$BASE/v1/admin/fanout/$CID" >/dev/null
sleep 3
AFTER=$(curl -fsS "$MAIL/api/v1/messages" | jq -r .total)
[ "$BEFORE" = "$AFTER" ] || fail "a repeated fan-out mailed again: $BEFORE -> $AFTER"
[ "$(curl -fsS "$BASE/v1/campaigns/$CID/deliveries" | jq -r .total)" = "4" ] || fail "a repeated fan-out duplicated rows"
say "idempotency: repeated fan-out, still 4 deliveries and 3 messages"

# 8. Negative paths stay explicit.
BAD=$(curl -s -o /tmp/arcod-036-bad.json -w '%{http_code}' -X POST "$BASE/v1/campaigns" \
  -H 'content-type: application/json' \
  -d '{"templateCode":"launch","name":"Empty","audience":[]}')
[ "$BAD" = "400" ] || fail "empty audience answered $BAD, want 400"
MISSING=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/campaigns/00000000-0000-0000-0000-000000000000")
[ "$MISSING" = "404" ] || fail "unknown campaign answered $MISSING, want 404"
say "errors: empty audience 400, unknown campaign 404"

echo "PASS: notification center (mysql + redis queue + s3 + mail gateway)"
