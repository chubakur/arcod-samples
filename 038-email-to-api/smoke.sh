#!/usr/bin/env bash
# End-to-end: postgres + redis queue + minio + an inbound mail provider + a
# subscriber sink on the compose network. Mail arrives at the provider, the
# cron hook queues ingest, the consumer writes body/attachments to S3 and rows
# to postgres, the second consumer signs and posts the payload, retries survive
# a subscriber outage, the dead letter is readable and replay recovers.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8098}"
INBOX_PORT="${INBOX_PORT:-9097}"
SINK_PORT="${SINK_PORT:-9098}"
BASE="http://localhost:${PORT}"
INBOX="http://localhost:${INBOX_PORT}"
SINK="http://localhost:${SINK_PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
RUN_PID=""
INBOX_NAME="arcod-038-inbox"
SINK_NAME="arcod-038-sink"

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
  docker rm -f "$INBOX_NAME" "$SINK_NAME" >/dev/null 2>&1 || true
  if [ -f .arcod/build/docker-compose.yml ]; then
    docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
  fi
  arcod_run run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

wait_http() {
  local url="$1" label="$2" tries="${3:-120}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "$url" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "$label did not answer at $url"
}

wait_until() {
  local expr="$1" label="$2" tries="${3:-60}"
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "$BASE/v1/stats" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if ($expr) else 1)"; then
      return 0
    fi
    sleep 1
  done
  echo "last stats: $(curl -fsS "$BASE/v1/stats" || true)" >&2
  fail "timed out waiting for $label"
}

echo "== build"
# The rows are the state; a rerun must start from an empty database, not from
# the previous run's mailboxes.
if [ -f .arcod/build/docker-compose.yml ]; then
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
fi
arcod_run run --down --impl >/dev/null 2>&1 || true
docker rm -f "$INBOX_NAME" "$SINK_NAME" >/dev/null 2>&1 || true
rm -rf .arcod
arcod_run check
arcod_run build --impl
say "check and build are clean"

echo "== start"
arcod_run run --impl --port "$PORT" > run.log 2>&1 &
RUN_PID=$!
wait_http "$BASE/v1/stats" "service"
say "service is up on :$PORT"

IMAGE=$(grep -m1 'image: arcod/email-bridge-service' .arcod/build/docker-compose.yml | awk '{print $2}')
SERVICE_ID=$(docker compose -f .arcod/build/docker-compose.yml ps -q service)
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$SERVICE_ID")
[ -n "$IMAGE" ] && [ -n "$NETWORK" ] || fail "cannot find the service image/network"

docker run -d --name "$INBOX_NAME" -p "${INBOX_PORT}:9097" --network "$NETWORK" --network-alias inbox \
  -v "$PWD/mock:/app" -w /app --entrypoint node "$IMAGE" inbox.mjs >/dev/null
docker run -d --name "$SINK_NAME" -p "${SINK_PORT}:9098" --network "$NETWORK" --network-alias sink \
  -v "$PWD/mock:/app" -w /app --entrypoint node "$IMAGE" sink.mjs >/dev/null
wait_http "$INBOX/healthz" "mock inbox"
wait_http "$SINK/healthz" "mock sink"
say "mock inbox and sink are on $NETWORK"

echo "== setup"
MB=$(curl -fsS -X POST "$BASE/v1/mailboxes" -H 'content-type: application/json' \
  -d '{"address":"support@acme.test"}')
MAILBOX=$(echo "$MB" | json 'd["id"]')
SECRET=$(echo "$MB" | json 'd["secret"]')
[ -n "$MAILBOX" ] && [ -n "$SECRET" ] || fail "mailbox create answered $MB"

DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/mailboxes" -H 'content-type: application/json' \
  -d '{"address":"support@acme.test"}')
[ "$DUP" = "409" ] || fail "duplicate mailbox answered $DUP, want 409"

BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/mailboxes" -H 'content-type: application/json' \
  -d '{"address":"no-at-sign"}')
[ "$BAD" = "400" ] || fail "invalid mailbox answered $BAD, want 400"

curl -fsS -X POST "$BASE/v1/routes" -H 'content-type: application/json' \
  -d "{\"mailboxId\":\"$MAILBOX\",\"topic\":\"tickets\",\"fromContains\":\"\",\"subjectContains\":\"ticket\"}" >/dev/null
ROUTES=$(curl -fsS "$BASE/v1/mailboxes/$MAILBOX" | json 'd["routes"]')
[ "$ROUTES" = "1" ] || fail "mailbox reports $ROUTES routes, want 1"
say "mailbox and one route are in postgres"

echo "== ingest"
curl -fsS -X POST "$INBOX/messages" -H 'content-type: application/json' \
  -d '{"mailbox":"support@acme.test","from":"bob@customer.test","subject":"New ticket: printer","text":"The printer is on fire.","attachments":[{"name":"photo.txt","contentType":"text/plain","contentBase64":"aGVsbG8="}]}' >/dev/null
curl -fsS -X POST "$INBOX/messages" -H 'content-type: application/json' \
  -d '{"mailbox":"support@acme.test","from":"news@vendor.test","subject":"Weekly digest","text":"Nothing to do."}' >/dev/null

POLL=$(curl -fsS -X POST "$BASE/v1/mailboxes/$MAILBOX/poll")
[ "$(echo "$POLL" | json 'd["queued"]')" = "1" ] || fail "poll answered $POLL"
wait_until 'd["delivered"] == 1 and d["ignored"] == 1' "one delivered and one ignored"
say "matched mail is delivered, unmatched mail is ignored"

COUNT=$(curl -fsS "$BASE/v1/messages" | json 'd["total"]')
[ "$COUNT" = "2" ] || fail "messages total is $COUNT, want 2"

MATCH=$(curl -fsS "$BASE/v1/messages" | json '[i["id"] for i in d["items"] if i["topic"]=="tickets"][0]')
DETAIL=$(curl -fsS "$BASE/v1/messages/$MATCH")
echo "$DETAIL" | json 'd["body"]' | grep -q 'printer is on fire' || fail "body did not round-trip through S3"
echo "$DETAIL" | json 'd["attachments"][0]["sha256"]' | grep -q '^2cf24dba' || fail "attachment digest is wrong"
echo "$DETAIL" | json 'd["message"]["digest"]' | grep -Eq '^[0-9a-f]{64}$' || fail "body digest is missing"
say "body and attachment went through S3; digests match"

echo "== signature"
FIRST=$(curl -fsS "$SINK/deliveries")
echo "$FIRST" | json 'len(d["deliveries"])' | grep -qx '1' || fail "sink has $(echo "$FIRST" | json 'len(d["deliveries"])') deliveries, want 1"
echo "$FIRST" | json 'd["deliveries"][0]["payload"]["topic"]' | grep -qx 'tickets' || fail "payload topic is wrong"
# recompute over exactly the fields the handler signs
read -r SIG_OK <<<"$(curl -fsS "$SINK/deliveries" | python3 -c "
import sys,json,hmac,hashlib
d=json.load(sys.stdin)['deliveries'][0]['payload']
canon='\n'.join([d['deliveryId'],d['messageId'],d['mailbox'],d['topic'],d['from'],d['subject'],str(d['receivedAt']),d['bodyKey']])
want=hmac.new('$SECRET'.encode(),canon.encode(),hashlib.sha256).hexdigest()
print('ok' if hmac.compare_digest(want,d['signature']) else 'bad')
")"
[ "$SIG_OK" = "ok" ] || fail "signature does not verify ($SIG_OK)"
say "payload signature verifies with the mailbox secret"

echo "== dedupe"
curl -fsS -X POST "$BASE/v1/mailboxes/$MAILBOX/poll" >/dev/null
sleep 3
COUNT=$(curl -fsS "$BASE/v1/messages" | json 'd["total"]')
[ "$COUNT" = "2" ] || fail "second poll duplicated rows: $COUNT"
say "a second poll at the same cursor inserted nothing"

echo "== retry"
curl -fsS -X POST "$SINK/fail" -H 'content-type: application/json' -d '{"times":2}' >/dev/null
curl -fsS -X POST "$INBOX/messages" -H 'content-type: application/json' \
  -d '{"mailbox":"support@acme.test","from":"eve@customer.test","subject":"Ticket: export","text":"Export is broken."}' >/dev/null
curl -fsS -X POST "$BASE/v1/mailboxes/$MAILBOX/poll" >/dev/null
wait_until 'd["delivered"] == 2 and d["failed"] == 0' "delivery after two subscriber failures"
say "two 503 answers were retried, the third attempt delivered"

echo "== dead letter"
curl -fsS -X POST "$SINK/fail" -H 'content-type: application/json' -d '{"times":3}' >/dev/null
curl -fsS -X POST "$INBOX/messages" -H 'content-type: application/json' \
  -d '{"mailbox":"support@acme.test","from":"eve@customer.test","subject":"Ticket: billing","text":"Invoice mismatch."}' >/dev/null
curl -fsS -X POST "$BASE/v1/mailboxes/$MAILBOX/poll" >/dev/null
wait_until 'd["failed"] == 1 and d["dead"] == 1' "dead letter after three failures"
FAILED=$(curl -fsS "$BASE/v1/messages" | json '[i["id"] for i in d["items"] if i["status"]=="failed"][0]')
DEAD=$(curl -fsS "$BASE/v1/dead")
echo "$DEAD" | grep -q '::' || fail "dead letter has no ids: $DEAD"
say "the exhausted delivery is in the queue's dead letter"

echo "== replay"
CODE=$(curl -s -o /tmp/arcod-038-replay.json -w '%{http_code}' -X POST "$BASE/v1/messages/$FAILED/replay")
[ "$CODE" = "201" ] || fail "replay answered $CODE"
wait_until 'd["delivered"] == 3 and d["failed"] == 0' "replay to deliver"
AGAIN=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/messages/$FAILED/replay")
[ "$AGAIN" = "409" ] || fail "replay of a delivered message answered $AGAIN, want 409"
say "replay recovered the message; a second replay is a 409"

echo "== 404"
MISS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/messages/00000000-0000-0000-0000-000000000000")
[ "$MISS" = "404" ] || fail "unknown message answered $MISS, want 404"
MISS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/mailboxes/00000000-0000-0000-0000-000000000000/poll")
[ "$MISS" = "404" ] || fail "unknown mailbox poll answered $MISS, want 404"
say "unknown ids answer 404"

echo "- stats: 4 messages, 3 delivered, 1 ignored, 1 attachment, 1 dead letter"
echo "PASS"
