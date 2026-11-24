#!/usr/bin/env bash
# 039-iot-telemetry: devices, samples, rules, alerts, pager, rollup, dead letter.
# Builds with the arcod under test, starts mysql + redis + s3 + the service,
# then checks every path over HTTP. Ends with PASS.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8096}"
SINK_PORT="${SINK_PORT:-9096}"
BASE="http://localhost:${PORT}"
SINK="http://localhost:${SINK_PORT}"
ARCOD="${ARCOD:-arcod}"

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
arcod_run() { $ARCOD "$@"; }

cleanup() {
  [ -n "${SINK_PID:-}" ] && kill "$SINK_PID" 2>/dev/null || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
rm -f /tmp/arcod-039-sink.log

cat > /tmp/arcod-039-sink.mjs <<'JS'
import http from 'node:http';
import fs from 'node:fs';
let failing = false;
let n = 0;
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    if (req.url === '/fail') { failing = true; res.end('{"ok":true}'); return; }
    if (req.url === '/ok') { failing = false; res.end('{"ok":true}'); return; }
    if (failing) {
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end('{"delivered":false}');
      return;
    }
    n += 1;
    fs.appendFileSync('/tmp/arcod-039-sink.log', body + '\n');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ delivered: true, ticket: 'PG-' + n }));
  });
});
server.listen(Number(process.env.SINK_PORT || 9096), '0.0.0.0');
JS
SINK_PORT="$SINK_PORT" node /tmp/arcod-039-sink.mjs >/tmp/arcod-039-sink.out 2>&1 &
SINK_PID=$!

say "check"
arcod_run check >/dev/null

say "build"
arcod_run build --impl --port "$PORT" >/dev/null

say "run"
arcod_run run --impl --port "$PORT" >/tmp/arcod-039.log 2>&1 &
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see /tmp/arcod-039.log)"
say "health: ok (service + mysql + redis + s3)"

say "devices"
DEV=$(curl -fsS -X POST "$BASE/v1/devices" -H 'content-type: application/json' \
  -d '{"name":"boiler-7","site":"plant-a","kind":"sensor"}')
DID=$(printf '%s' "$DEV" | jq -r .id)
[ -n "$DID" ] && [ "$DID" != null ] || fail "device id missing"
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/devices" -H 'content-type: application/json' \
  -d '{"name":"boiler-7","site":"plant-a","kind":"sensor"}')
[ "$DUP" = "409" ] || fail "duplicate device answered $DUP, want 409"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/devices" -H 'content-type: application/json' -d '{"name":"","site":"x"}')
[ "$BAD" = "400" ] || fail "nameless device answered $BAD, want 400"
say "device: created, duplicate 409, empty name 400"

say "rules"
curl -fsS -X POST "$BASE/v1/rules" -H 'content-type: application/json' \
  -d '{"rule":{"deviceId":"'"$DID"'","metric":"temp","op":"gt","threshold":80,"cooldownSec":60,"severity":"warning"}}' >/dev/null
curl -fsS -X POST "$BASE/v1/rules" -H 'content-type: application/json' \
  -d '{"rule":{"metric":"pressure","op":"lt","threshold":990,"cooldownSec":60,"severity":"critical"}}' >/dev/null
curl -fsS -X POST "$BASE/v1/rules" -H 'content-type: application/json' \
  -d '{"rule":{"deviceId":"'"$DID"'","metric":"vibration","op":"gt","threshold":5,"cooldownSec":0,"severity":"critical"}}' >/dev/null
RULES=$(curl -fsS "$BASE/v1/rules")
[ "$(printf '%s' "$RULES" | jq 'length')" = "3" ] || fail "expected 3 rules, got $RULES"
BADOP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/rules" -H 'content-type: application/json' \
  -d '{"rule":{"metric":"temp","op":"eq","threshold":1}}')
[ "$BADOP" = "400" ] || fail "unknown op answered $BADOP, want 400"
say "rules: 3 accepted, unknown op 400"

say "ingest"
ING=$(curl -fsS -X POST "$BASE/v1/devices/$DID/readings" -H 'content-type: application/json' \
  -d '{"samples":[{"metric":"temp","value":21.5,"at":"2026-11-24T12:00:00Z"},{"metric":"temp","value":85.2,"at":"2026-11-24T12:01:00Z"},{"metric":"pressure","value":980,"at":"2026-11-24T12:02:00Z"}]}')
[ "$(printf '%s' "$ING" | jq -r .accepted)" = "3" ] || fail "ingest accepted != 3: $ING"
NODEV=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/devices/00000000-0000-4000-8000-000000000000/readings" \
  -H 'content-type: application/json' -d '{"samples":[{"metric":"temp","value":1,"at":"2026-11-24T12:00:00Z"}]}')
[ "$NODEV" = "404" ] || fail "unknown device ingest answered $NODEV, want 404"
say "ingest: 3 samples stored; unknown device 404"

say "alerts (background evaluation)"
for _ in $(seq 1 30); do
  N=$(curl -fsS "$BASE/v1/alerts?status=open" | jq '.total')
  [ "$N" -ge 2 ] && break
  sleep 1
done
[ "$N" -ge 2 ] || fail "expected 2 open alerts, got $N"
ALERTS=$(curl -fsS "$BASE/v1/alerts?status=open")
AID=$(printf '%s' "$ALERTS" | jq -r '.items[] | select(.metric=="temp") | .id' | head -1)
[ -n "$AID" ] || fail "no temp alert"
[ "$(printf '%s' "$ALERTS" | jq -r '.items[] | select(.metric=="pressure") | .value')" = "980" ] || fail "pressure alert lost its value"
for _ in $(seq 1 20); do
  L=0
  [ -f /tmp/arcod-039-sink.log ] && L=$(wc -l < /tmp/arcod-039-sink.log | tr -d ' ')
  [ "$L" -ge 2 ] && break
  sleep 1
done
L=0
[ -f /tmp/arcod-039-sink.log ] && L=$(wc -l < /tmp/arcod-039-sink.log | tr -d ' ')
[ "$L" -ge 2 ] || fail "pager got fewer than 2 notifications"
grep -q "$AID" /tmp/arcod-039-sink.log || fail "pager did not see alert $AID"
say "alerts: temp>80 and pressure<990 opened, pager notified twice"

say "readings"
T=$(curl -fsS "$BASE/v1/devices/$DID/readings?metric=temp")
[ "$(printf '%s' "$T" | jq 'length')" = "2" ] || fail "expected 2 temp readings: $T"
[ "$(printf '%s' "$T" | jq -r '.[0].value')" = "85.2" ] || fail "newest temp reading is not first"
say "readings: newest first, metric filter works"

say "ack / resolve"
ACK=$(curl -s -o /tmp/arcod-039-ack.json -w '%{http_code}' -X POST "$BASE/v1/alerts/$AID/ack")
[ "$ACK" = "200" ] || fail "ack answered $ACK, want 200"
[ "$(jq -r .status /tmp/arcod-039-ack.json)" = "acked" ] || fail "ack did not set status"
RES=$(curl -s -o /tmp/arcod-039-res.json -w '%{http_code}' -X POST "$BASE/v1/alerts/$AID/resolve")
[ "$RES" = "200" ] || fail "resolve answered $RES, want 200"
[ "$(jq -r .status /tmp/arcod-039-res.json)" = "resolved" ] || fail "resolve did not set status"
AGAIN=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/alerts/$AID/resolve")
[ "$AGAIN" = "409" ] || fail "second resolve answered $AGAIN, want 409"
say "ack 200 acked, resolve 200 resolved, repeat 409"

say "cooldown"
BEFORE=$(curl -fsS "$BASE/v1/alerts?status=all" | jq '.total')
curl -fsS -X POST "$BASE/v1/devices/$DID/readings" -H 'content-type: application/json' \
  -d '{"samples":[{"metric":"temp","value":91.4,"at":"2026-11-24T12:03:00Z"}]}' >/dev/null
sleep 3
AFTER=$(curl -fsS "$BASE/v1/alerts?status=all" | jq '.total')
[ "$BEFORE" = "$AFTER" ] || fail "cooldown did not hold: $BEFORE -> $AFTER"
say "cooldown: second breach inside 60s opened no alert"

say "stats"
S=$(curl -fsS "$BASE/v1/stats")
[ "$(printf '%s' "$S" | jq -r .devices)" = "1" ] || fail "stats.devices: $S"
[ "$(printf '%s' "$S" | jq -r .readings)" = "4" ] || fail "stats.readings: $S"
[ "$(printf '%s' "$S" | jq -r .rules)" = "3" ] || fail "stats.rules: $S"
[ "$(printf '%s' "$S" | jq -r .openAlerts)" = "1" ] || fail "stats.openAlerts: $S"
say "stats: 1 device, 4 readings, 3 rules, 1 open alert"

say "report job"
REP=$(curl -fsS -X POST "$BASE/v1/reports")
RID=$(printf '%s' "$REP" | jq -r .id)
for _ in $(seq 1 30); do
  ST=$(curl -fsS "$BASE/v1/reports/$RID" | jq -r .status)
  [ "$ST" = "ready" ] && break
  sleep 1
done
[ "$ST" = "ready" ] || fail "report stayed $ST"
FILE=$(curl -fsS "$BASE/v1/reports/$RID/file")
ROWS=$(printf '%s' "$FILE" | jq -r .content | sed '/^$/d' | wc -l | tr -d ' ')
[ "$ROWS" = "5" ] || fail "CSV line count: $ROWS"
printf '%s' "$FILE" | jq -r .content | grep -q '^deviceId,metric,value,at' || fail "CSV header missing"
printf '%s' "$FILE" | jq -r .content | grep -q '85.2' || fail "CSV lost the breaching sample"
say "report: queued -> ready, CSV in S3 has header + 4 rows"

say "dead letter"
curl -fsS "$SINK/fail" >/dev/null
curl -fsS -X POST "$BASE/v1/devices/$DID/readings" -H 'content-type: application/json' \
  -d '{"samples":[{"metric":"vibration","value":9.9,"at":"2026-11-24T12:04:00Z"}]}' >/dev/null
for _ in $(seq 1 30); do
  D=$(curl -fsS "$BASE/v1/dead" | jq '.items | length')
  [ "$D" -ge 1 ] && break
  sleep 1
done
[ "$D" -ge 1 ] || fail "pager failure produced no dead letter"
LINE=$(curl -fsS "$BASE/v1/dead" | jq -r '.items[0]')
printf '%s' "$LINE" | grep -q 'vibration' || fail "dead entry is not the failed sample: $LINE"
DROP=$(curl -fsS -X POST "$BASE/v1/dead/drop" -H 'content-type: application/json' \
  --data-binary "$(jq -n --arg p "$LINE" '{payload:$p}')")
[ "$(printf '%s' "$DROP" | jq -r .dropped)" = "true" ] || fail "dropDead returned $DROP"
LEFT=$(curl -fsS "$BASE/v1/dead" | jq '.items | length')
[ "$LEFT" = "0" ] || fail "dead list still has $LEFT entries after drop"
curl -fsS "$SINK/ok" >/dev/null
say "dead: failed pager call retried into the dead letter, then dropped"

say "PASS"
