#!/usr/bin/env bash
# 051-fraud-shield: a payment anti-fraud pipeline. The checkout stores an
# attempt and returns; a scoring consumer evaluates rules, calls the external
# risk vendor, writes one decision and opens a review case with evidence in S3.
# Five external systems: postgres, redis, minio, a risk vendor (host mock),
# and a websocket feed. Two consumers: score and notify.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8098}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-051.log
MOCKLOG=/tmp/arcod-051-mock.log
BODY=/tmp/arcod-051-body.json
COMPOSE=.arcod/build/docker-compose.yml
DAY=$(date -u +%F)

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:-$BODY}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" >/dev/null 2>&1 || true
  docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

pkill -f 'mocks/risk.mjs' >/dev/null 2>&1 || true

json_post() { curl -sS -o "$BODY" -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
json_get() { curl -sS -o "$BODY" -w '%{http_code}' "$BASE$1"; }
post() { json_post "$1" "$2" >/dev/null; cat "$BODY"; }
getj() { json_get "$1" >/dev/null; cat "$BODY"; }
code() { json_post "$1" "$2"; }

wait_attempt() {
  local id="$1" want="$2"
  for _ in $(seq 1 240); do
    json_get "/v1/attempts/$id" >/dev/null 2>&1 || true
    local s
    s=$(J .attempt.status 2>/dev/null || echo pending)
    if [ "$s" = "$want" ]; then return 0; fi
    if [ "$s" != "pending" ] && [ "$want" != "any" ]; then return 1; fi
    sleep 0.25
  done
  return 1
}

submit() { # merchantId json -> attempt id
  json_post "/v1/merchants/$1/attempts" "$2" >/dev/null
  J .id
}

docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true

say "check"
$ARCOD check >/dev/null

say "build"
$ARCOD build --impl --port "$PORT" >/dev/null

say "risk vendor on the host (:9096)"
node mocks/risk.mjs >"$MOCKLOG" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  curl -fsS http://localhost:9096/healthz >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS http://localhost:9096/healthz >/dev/null || { cat "$MOCKLOG"; fail "mock risk vendor did not start"; }

say "run"
$ARCOD run --impl --port "$PORT" >"$LOG" 2>&1 &
RUN_PID=$!
for _ in $(seq 1 240); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -100 "$LOG"; fail "service did not start"; }

say "merchants: create, duplicate 409, bad limit 400"
[ "$(json_post /v1/merchants '{"name":"shop-a","dailyLimit":100000}')" = "201" ] || fail "createMerchant must be 201"
M1=$(J .id); [ -n "$M1" ] || fail "merchant id missing"
[ "$(J .dailyLimit)" = "100000" ] || fail "dailyLimit not stored"
[ "$(json_post /v1/merchants '{"name":"shop-a"}')" = "409" ] || fail "duplicate merchant must be 409"
[ "$(json_post /v1/merchants '{"name":"bad","dailyLimit":-5}')" = "400" ] || fail "negative limit must be 400"
[ "$(json_post /v1/merchants '{"name":"shop-b","dailyLimit":5000}')" = "201" ] || fail "second merchant must be 201"
M2=$(J .id)

say "rules: four kinds, duplicate 409, bad kind 400"
[ "$(json_post /v1/rules '{"name":"card-velocity","kind":"velocity","action":"review","threshold":3,"windowSeconds":600}')" = "201" ] || fail "velocity rule must be 201"
[ "$(json_post /v1/rules '{"name":"large-amount","kind":"amount_limit","action":"review","threshold":50000}')" = "201" ] || fail "amount rule must be 201"
[ "$(json_post /v1/rules '{"name":"stolen-card","kind":"blocklist","action":"decline","value":"card-stolen"}')" = "201" ] || fail "blocklist rule must be 201"
[ "$(json_post /v1/rules '{"name":"risk-score","kind":"score","action":"review","threshold":70}')" = "201" ] || fail "score rule must be 201"
[ "$(json_post /v1/rules '{"name":"large-amount","kind":"score","threshold":10}')" = "409" ] || fail "duplicate rule must be 409"
[ "$(json_post /v1/rules '{"name":"weird","kind":"magic","threshold":1}')" = "400" ] || fail "unknown kind must be 400"
[ "$(json_post /v1/rules '{"name":"empty-block","kind":"blocklist","action":"decline"}')" = "400" ] || fail "empty blocklist value must be 400"
[ "$(getj /v1/rules | jq 'length')" = "4" ] || fail "four rules expected"
[ "$(code "/v1/merchants/nope/attempts" '{"cardFingerprint":"x","amount":100}')" = "404" ] || fail "unknown merchant must be 404"

say "attempt 1: approved, one decision, no case"
A1=$(submit "$M1" '{"cardFingerprint":"card-ok","amount":1200,"clientRef":"ok-1","customerEmail":"buyer@example.com"}')
[ -n "$A1" ] || fail "attempt id missing"
[ "$(J .status)" = "pending" ] || fail "a fresh attempt must be pending"
wait_attempt "$A1" approved || { getj "/v1/attempts/$A1"; fail "attempt 1 was not approved"; }
D1=$(getj "/v1/attempts/$A1")
[ "$(printf '%s' "$D1" | jq -r '.attempt.score')" = "5" ] || fail "vendor score must be 5"
[ "$(printf '%s' "$D1" | jq -r '.attempt.ruleHits')" = "0" ] || fail "no rule should fire"
[ "$(printf '%s' "$D1" | jq -r '.decision | length')" = "1" ] || fail "one decision expected"
[ "$(printf '%s' "$D1" | jq -r '.cases | length')" = "0" ] || fail "approved attempt must have no case"
[ "$(curl -sS http://localhost:9096/stats | jq -r .calls)" -ge 1 ] || fail "vendor was not called"

say "idempotency: the same clientRef returns the same attempt"
REPEAT=$(post "/v1/merchants/$M1/attempts" '{"cardFingerprint":"card-ok","amount":1200,"clientRef":"ok-1"}')
[ "$(printf '%s' "$REPEAT" | J .id)" = "$A1" ] || fail "repeat must return the original attempt"
[ "$(getj /v1/attempts | jq 'length')" = "1" ] || fail "repeat must not create a second attempt"

say "blocklist: declined, case + evidence in S3"
A2=$(submit "$M1" '{"cardFingerprint":"card-stolen","amount":900,"clientRef":"stolen-1"}')
wait_attempt "$A2" declined || fail "blocklisted attempt must be declined"
D2=$(getj "/v1/attempts/$A2")
[ "$(printf '%s' "$D2" | jq -r '.attempt.reasons')" = "blocklist:stolen-card" ] || fail "blocklist reason missing"
CASE2=$(printf '%s' "$D2" | jq -r '.cases[0].id')
[ -n "$CASE2" ] && [ "$CASE2" != "null" ] || fail "declined attempt must open a case"
EV=$(getj "/v1/cases/$CASE2/evidence")
[ "$(printf '%s' "$EV" | jq -r .key)" = "evidence/$A2.json" ] || fail "evidence key mismatch"
[ "$(printf '%s' "$EV" | jq -r .content | jq -r .decision.outcome)" = "declined" ] || fail "evidence must carry the decision"
[ "$(printf '%s' "$EV" | jq -r .content | jq -r .attempt.cardFingerprint)" = "card-stolen" ] || fail "evidence must carry the attempt"

say "amount limit: review, case opened"
A3=$(submit "$M1" '{"cardFingerprint":"card-big","amount":60000,"clientRef":"big-1"}')
wait_attempt "$A3" review || fail "large amount must go to review"
D3=$(getj "/v1/attempts/$A3")
[ "$(printf '%s' "$D3" | jq -r '.attempt.reasons' | grep -c 'amount_limit:60000>50000')" = "1" ] || fail "amount_limit reason missing"
[ "$(printf '%s' "$D3" | jq -r '.cases | length')" = "1" ] || fail "review must open a case"

say "external score: XX country scores 88 and goes to review"
A4=$(submit "$M1" '{"cardFingerprint":"card-xx","amount":1000,"country":"XX","clientRef":"xx-1"}')
wait_attempt "$A4" review || fail "high-risk country must go to review"
D4=$(getj "/v1/attempts/$A4")
[ "$(printf '%s' "$D4" | jq -r '.attempt.score')" = "88" ] || fail "vendor score not stored"
[ "$(printf '%s' "$D4" | jq -r '.attempt.reasons' | grep -c 'score:88>=70')" = "1" ] || fail "score reason missing"
[ "$(printf '%s' "$D4" | jq -r '.attempt.reasons' | grep -c 'high_risk_country')" = "1" ] || fail "vendor reason missing"

say "vendor outage: fail-closed to review, never approved"
A5=$(submit "$M1" '{"cardFingerprint":"card-down","amount":1000,"country":"DOWN","clientRef":"down-1"}')
wait_attempt "$A5" review || fail "vendor outage must go to review"
D5=$(getj "/v1/attempts/$A5")
[ "$(printf '%s' "$D5" | jq -r '.attempt.reasons' | grep -c 'scoring_unavailable')" = "1" ] || fail "scoring_unavailable reason missing"
[ "$(printf '%s' "$D5" | jq -r '.attempt.score')" = "0" ] || fail "outage score must be 0"

say "velocity: three attempts pass, the fourth is reviewed"
for i in 1 2 3; do
  AF=$(submit "$M1" "{\"cardFingerprint\":\"card-fast\",\"amount\":100,\"clientRef\":\"fast-$i\"}")
  wait_attempt "$AF" approved || fail "velocity attempt $i must be approved"
done
AF4=$(submit "$M1" '{"cardFingerprint":"card-fast","amount":100,"clientRef":"fast-4"}')
wait_attempt "$AF4" review || fail "the fourth attempt must be reviewed"
[ "$(getj "/v1/attempts/$AF4" | jq -r '.attempt.reasons' | grep -c 'velocity:4>3/600s')" = "1" ] || fail "velocity reason missing"

say "daily cap: approved total plus this amount crosses the merchant limit"
B1=$(submit "$M2" '{"cardFingerprint":"card-b1","amount":3000,"clientRef":"b-1"}')
wait_attempt "$B1" approved || fail "first daily attempt must be approved"
B2=$(submit "$M2" '{"cardFingerprint":"card-b2","amount":3000,"clientRef":"b-2"}')
wait_attempt "$B2" review || fail "second daily attempt must be reviewed"
[ "$(getj "/v1/attempts/$B2" | jq -r '.attempt.reasons' | grep -c 'daily_limit:6000>5000')" = "1" ] || fail "daily_limit reason missing"

say "case: resolve once, conflict on the second, 404 on unknown"
RES=$(post "/v1/cases/$CASE2/resolve" '{"assignee":"alice","notes":"stolen card confirmed"}')
[ "$(printf '%s' "$RES" | J .status)" = "resolved" ] || fail "resolve did not stick"
[ "$(printf '%s' "$RES" | J .notes)" = "stolen card confirmed" ] || fail "notes not saved"
[ "$(json_post "/v1/cases/$CASE2/resolve" '{"notes":"again"}')" = "409" ] || fail "second resolve must be 409"
[ "$(json_post "/v1/cases/nope/resolve" '{}')" = "404" ] || fail "unknown case must be 404"

say "report: a real JSON object in S3"
[ "$(json_post /v1/reports "{\"day\":\"$DAY\"}")" = "201" ] || fail "report must be 201"
REP=$(cat "$BODY")
[ "$(printf '%s' "$REP" | jq -r .key)" = "reports/$DAY.json" ] || fail "report key mismatch"
CT=$(printf '%s' "$REP" | jq -r .content)
[ "$(printf '%s' "$CT" | jq -r .attempts)" = "11" ] || fail "report must count 11 attempts"
[ "$(printf '%s' "$CT" | jq -r .approved)" = "5" ] || fail "report approved must be 5"
[ "$(printf '%s' "$CT" | jq -r .review)" = "5" ] || fail "report review must be 5"
[ "$(printf '%s' "$CT" | jq -r .declined)" = "1" ] || fail "report declined must be 1"
[ "$(printf '%s' "$CT" | jq -r .approvedAmount)" = "4500" ] || fail "approved amount must be 4500"
[ "$(json_post /v1/reports '{"day":"27-11-2026"}')" = "400" ] || fail "bad day must be 400"

say "stats: counters, average score, open cases"
ST=$(getj /v1/stats)
[ "$(printf '%s' "$ST" | jq -r .attempts)" = "11" ] || fail "stats attempts must be 11"
[ "$(printf '%s' "$ST" | jq -r .declined)" = "1" ] || fail "stats declined must be 1"
[ "$(printf '%s' "$ST" | jq -r .openCases)" = "5" ] || fail "stats openCases must be 5"
[ "$(printf '%s' "$ST" | jq -r '.avgScore > 0')" = "true" ] || fail "avgScore must be positive"

say "websocket: a decision reaches a subscriber"
WS_LOG=$(mktemp)
node -e '
const [topic, port, out] = process.argv.slice(1);
const fs = require("fs");
const ws = new WebSocket("ws://localhost:" + port + "/ws?topic=" + topic);
const timer = setTimeout(() => { try { fs.writeFileSync(out, "timeout"); } catch {} process.exit(1); }, 25000);
ws.onmessage = (e) => { try { fs.appendFileSync(out, e.data + "\n"); } catch {} };
ws.onerror = () => { try { fs.writeFileSync(out, "error"); } catch {} process.exit(1); };
' risk "$PORT" "$WS_LOG" &
WS_PID=$!
sleep 1
A6=$(submit "$M1" '{"cardFingerprint":"card-ws","amount":1500,"clientRef":"ws-1"}')
wait_attempt "$A6" approved || fail "websocket attempt must be approved"
for _ in $(seq 1 60); do grep -q "$A6" "$WS_LOG" 2>/dev/null && break; sleep 0.25; done
grep -q "\"attemptId\":\"$A6\"" "$WS_LOG" || fail "websocket did not receive the attempt (log: $(cat "$WS_LOG" 2>/dev/null))"
grep -q '"type":"decision"' "$WS_LOG" || fail "websocket did not receive a decision"
kill "$WS_PID" >/dev/null 2>&1 || true

say "sweep is idempotent when nothing is stale; dead letter is empty"
[ "$(post /v1/sweep "{\"now\":\"$(date -u +%FT%TZ)\"}" | jq -r .stale)" = "0" ] || fail "nothing must be stale"
[ "$(post /v1/sweep "{\"now\":\"$(date -u +%FT%TZ)\"}" | jq -r .stale)" = "0" ] || fail "second sweep must also be 0"
[ "$(getj /v1/dead | jq 'length')" = "0" ] || fail "dead letter must be empty"

say "validation: amount and fingerprint"
[ "$(json_post "/v1/merchants/$M1/attempts" '{"cardFingerprint":"x","amount":0}')" = "400" ] || fail "zero amount must be 400"
[ "$(json_post "/v1/merchants/$M1/attempts" '{"cardFingerprint":"x","amount":-5}')" = "400" ] || fail "negative amount must be 400"
[ "$(json_post "/v1/merchants/$M1/attempts" '{"amount":100}')" = "400" ] || fail "missing fingerprint must be 400"

say "PASS"
