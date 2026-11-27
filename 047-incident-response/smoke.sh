#!/usr/bin/env bash
# 047-incident-response: services, on-call shifts, alert ingestion with a
# five-minute dedup window, ack/resolve state machine, SLA sweep, live
# websocket feed, markdown postmortem in S3. Four providers: postgres, redis
# (queue), minio (blob), websocket (stream). Two consumers: notify and
# postmortemDoc.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8095}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-047.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:--}"; }
# $1 is a signed number of minutes relative to now.
iso() { node -e 'console.log(new Date(Date.now() + Number(process.argv[1]) * 60000).toISOString().replace(/\.\d+Z$/, "Z"))' -- "$1"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  [ -n "${WS_PID:-}" ] && kill "$WS_PID" >/dev/null 2>&1 || true
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
RUN_PID=$!
for _ in $(seq 1 150); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -60 "$LOG"; fail "service did not start"; }

post() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
code() { curl -sS -o /tmp/arcod-047-body.json -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
getc() { curl -sS -o /tmp/arcod-047-body.json -w '%{http_code}' "$BASE$1"; }

say "services: create, duplicate name, unknown"
SVC=$(post /v1/services '{"name":"payments","tier":"T1","runbook":"https://runbooks/payments"}' | J .id)
[ -n "$SVC" ] && [ "$SVC" != null ] || fail "service was not created"
[ "$(code /v1/services '{"name":"payments"}')" = "409" ] || fail "duplicate service name must be 409"
[ "$(code /v1/services '{"name":"","tier":"T1"}')" = "400" ] || fail "empty name must be 400"
OTHER=$(post /v1/services '{"name":"search","tier":"T3"}' | J .id)

say "shifts: on-call lookup, overlap 409, bad interval 400"
START=$(iso -60)
END=$(iso 420)
SHIFT=$(post "/v1/services/$SVC/shifts" "{\"agent\":\"alice\",\"startsAt\":\"$START\",\"endsAt\":\"$END\"}" | J .id)
[ -n "$SHIFT" ] && [ "$SHIFT" != null ] || fail "shift was not created"
[ "$(curl -sS "$BASE/v1/services/$SVC/on-call" | J .agent)" = "alice" ] || fail "on-call is not alice"
OVER=$(jq -nc --arg s "$(iso 60)" --arg e "$(iso 120)" '{agent:"bob", startsAt:$s, endsAt:$e}')
[ "$(code "/v1/services/$SVC/shifts" "$OVER")" = "409" ] || fail "overlapping shift must be 409"
BACK=$(jq -nc --arg s "$END" --arg e "$START" '{agent:"bob", startsAt:$s, endsAt:$e}')
[ "$(code "/v1/services/$SVC/shifts" "$BACK")" = "400" ] || fail "reversed interval must be 400"
[ "$(getc "/v1/services/nope/on-call")" = "404" ] || fail "unknown service on-call must be 404"
[ "$(getc "/v1/incidents/nope")" = "404" ] || fail "unknown incident must be 404"

say "alert: new incident, consumer assigns the on-call agent"
A1=$(post /v1/alerts "{\"serviceId\":\"$SVC\",\"fingerprint\":\"db-cpu\",\"title\":\"Database CPU above 95%\",\"severity\":\"SEV2\"}")
INC1=$(printf '%s' "$A1" | J .incidentId)
[ "$(printf '%s' "$A1" | J .deduped)" = "false" ] || fail "first alert must not be deduped"
VIEW=""
for _ in $(seq 1 40); do
  VIEW=$(curl -sS "$BASE/v1/incidents/$INC1")
  [ "$(printf '%s' "$VIEW" | J .incident.assignee)" = "alice" ] && break
  sleep 0.25
done
[ "$(printf '%s' "$VIEW" | J .incident.assignee)" = "alice" ] || fail "consumer did not assign alice: $VIEW"
ASSIGNED=$(printf '%s' "$VIEW" | jq '[.events[] | select(.kind=="assigned")] | length')
[ "$ASSIGNED" = "1" ] || fail "assignment event missing"

say "dedup: same fingerprint inside five minutes folds into the incident"
A2=$(post /v1/alerts "{\"serviceId\":\"$SVC\",\"fingerprint\":\"db-cpu\",\"title\":\"Database CPU above 95%\",\"severity\":\"SEV2\"}")
[ "$(printf '%s' "$A2" | J .deduped)" = "true" ] || fail "repeat alert must be deduped"
[ "$(printf '%s' "$A2" | J .incidentId)" = "$INC1" ] || fail "dedup opened a second incident"
[ "$(printf '%s' "$A2" | J .dedupCount)" = "2" ] || fail "dedupCount is not 2"
A3=$(post /v1/alerts "{\"serviceId\":\"$SVC\",\"fingerprint\":\"cache-errors\",\"title\":\"Cache error rate\",\"severity\":\"SEV1\"}")
INC3=$(printf '%s' "$A3" | J .incidentId)
[ "$INC3" != "$INC1" ] || fail "different fingerprint reused the incident"
BAD=$(jq -nc --arg svc "$SVC" '{serviceId:$svc, fingerprint:"y", title:"y", severity:"SEV9"}')
[ "$(code /v1/alerts "$BAD")" = "400" ] || fail "unknown severity must be 400"
NOPE=$(jq -nc '{serviceId:"nope", fingerprint:"y", title:"y"}')
[ "$(code /v1/alerts "$NOPE")" = "404" ] || fail "unknown service alert must be 404"

say "websocket: acknowledgement reaches a subscriber"
WS_LOG=$(mktemp)
node -e '
const [topic, port, out] = process.argv.slice(1);
const fs = require("fs");
const ws = new WebSocket("ws://localhost:" + port + "/ws?topic=" + topic);
const timer = setTimeout(() => { try { fs.writeFileSync(out, "timeout"); } catch {} process.exit(1); }, 15000);
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "incident" && m.event === "acknowledged") {
    clearTimeout(timer);
    fs.writeFileSync(out, m.event + ":" + m.status);
    ws.close();
    process.exit(0);
  }
};
ws.onerror = () => { try { fs.writeFileSync(out, "error"); } catch {} process.exit(1); };
' "service:$SVC" "$PORT" "$WS_LOG" &
WS_PID=$!
for _ in $(seq 1 40); do [ -s "$WS_LOG" ] && break; sleep 0.1; done

say "ack: idempotent, mtta recorded"
ACK=$(post "/v1/incidents/$INC1/ack" '{"actor":"alice"}')
[ "$(printf '%s' "$ACK" | J .status)" = "acked" ] || fail "ack did not move the incident"
[ "$(printf '%s' "$ACK" | J .ackedAt)" != "null" ] || fail "ackedAt is empty"
[ "$(post "/v1/incidents/$INC1/ack" '{"actor":"alice"}' | J .status)" = "acked" ] || fail "second ack must be a no-op"
wait "$WS_PID" || true
grep -q 'acknowledged:acked' "$WS_LOG" || fail "websocket did not receive acknowledged (log: $(cat "$WS_LOG" 2>/dev/null))"

say "resolve: postmortem consumer writes markdown to S3"
[ "$(post "/v1/incidents/$INC1/resolve" '{"actor":"alice","summary":"Connection pool exhausted by a migration"}' | J .status)" = "resolved" ] || fail "resolve did not stick"
PM=""
for _ in $(seq 1 40); do
  PM=$(curl -sS "$BASE/v1/incidents/$INC1/postmortem")
  printf '%s' "$PM" | jq -e '.key' >/dev/null 2>&1 && break
  sleep 0.25
done
printf '%s' "$PM" | jq -e '.key' >/dev/null 2>&1 || fail "postmortem object was not created: $PM"
printf '%s' "$PM" | jq -e '.content | contains("## Timeline")' >/dev/null || fail "postmortem has no timeline"
printf '%s' "$PM" | jq -e '.content | contains("acknowledged")' >/dev/null || fail "postmortem lost the ack event"
[ "$(printf '%s' "$PM" | J .key)" = "postmortems/$INC1.md" ] || fail "postmortem key is not the incident id"
[ "$(code "/v1/incidents/$INC1/ack" '{"actor":"alice"}')" = "409" ] || fail "ack after resolve must be 409"
[ "$(code "/v1/incidents/$INC1/resolve" '{"actor":"alice"}')" = "409" ] || fail "double resolve must be 409"

say "sweep: an unacked SEV1 older than its SLA is escalated once"
A4=$(post /v1/alerts "{\"serviceId\":\"$SVC\",\"fingerprint\":\"kafka-lag\",\"title\":\"Kafka consumer lag\",\"severity\":\"SEV1\",\"observedAt\":\"$(iso -10)\"}")
INC4=$(printf '%s' "$A4" | J .incidentId)
SW=$(post /v1/sweep "{\"now\":\"$(iso 0)\"}")
[ "$(printf '%s' "$SW" | J .breached)" -ge 1 ] || fail "sweep found no breach: $SW"
[ "$(post /v1/sweep "{\"now\":\"$(iso 0)\"}" | J .escalated)" = "0" ] || fail "sweep escalated the same incident twice"
[ "$(curl -sS "$BASE/v1/incidents/$INC4" | jq -r '.incident.escalated')" = "true" ] || fail "incident is not marked escalated"

say "stats and dead letters"
STATS=$(curl -sS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | J .services)" = "2" ] || fail "stats.services is not 2"
[ "$(printf '%s' "$STATS" | J .resolved)" = "1" ] || fail "stats.resolved is not 1"
[ "$(printf '%s' "$STATS" | J .deduped)" = "1" ] || fail "stats.deduped is not 1"
[ "$(printf '%s' "$STATS" | J .mttaSeconds)" -ge 0 ] || fail "mtta is negative"
[ "$(curl -sS "$BASE/v1/dead" | jq length)" = "0" ] || fail "dead letter queue is not empty: $(curl -sS "$BASE/v1/dead")"
printf '%s' "$STATS" | jq .

echo
echo "PASS 047-incident-response"
