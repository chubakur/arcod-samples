#!/usr/bin/env bash
# End-to-end smoke: definitions, DAG validation, a run that survives retries and
# a timer, compensation in reverse order, cancel, schedules, two ticks racing on
# one claim, and the 400/404 edges. Ends with PASS.
set -euo pipefail
cd "$(dirname "$0")"

ARCOD="${ARCOD:-arcod}"
PORT="${PORT:-8091}"
BASE="http://localhost:${PORT}"
LOG="${LOG:-/tmp/arcod-flow-engine.log}"

cleanup() {
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
post() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
get() { curl -sS "$BASE$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$BASE$1"; }
postcode() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }

WORKFLOW='{"name":"order","steps":[
  {"name":"validate","action":"ok","after":"","key":"","value":"valid","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""},
  {"name":"charge","action":"flaky","after":"validate","key":"","value":"charged","delayMs":0,"retry":2,"backoffMs":200,"failFirst":1,"compensate":"refund"},
  {"name":"ship","action":"ok","after":"charge","key":"","value":"shipped","delayMs":300,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""},
  {"name":"notify","action":"set","after":"ship","key":"note","value":"shipped {{input}}","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""}
]}'

# Start from nothing: no containers, no old build, no stale keys.
cleanup
rm -rf .arcod

say "check"
"$ARCOD" check >/dev/null

say "build"
"$ARCOD" build --impl >/dev/null

say "start :${PORT}"
"$ARCOD" run --impl --port "$PORT" >"$LOG" 2>&1 &
for _ in $(seq 1 90); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/health" 2>/dev/null || true)" = "200" ] && break
  sleep 1
done
[ "$(code /v1/health)" = "200" ] || { echo "service did not start"; tail -40 "$LOG"; exit 1; }

say "health is empty"
H=$(get /v1/health)
[ "$(echo "$H" | jq -r .ok)" = "true" ]
[ "$(echo "$H" | jq -r .workflows)" = "0" ]
[ "$(echo "$H" | jq -r .runs)" = "0" ]

say "create a definition"
W=$(post /v1/workflows "$WORKFLOW")
[ "$(echo "$W" | jq -r .name)" = "order" ]
[ "$(echo "$W" | jq -r '.steps | length')" = "4" ]
[ "$(get /v1/workflows | jq -r 'length')" = "1" ]
[ "$(get /v1/workflows/order | jq -r '.steps[3].action')" = "set" ]

say "definitions are validated at the edge"
[ "$(postcode /v1/workflows "$WORKFLOW")" = "409" ]
[ "$(postcode /v1/workflows '{"name":"bad name","steps":[]}')" = "400" ]
[ "$(postcode /v1/workflows '{"name":"cycle","steps":[{"name":"a","action":"ok","after":"b","key":"","value":"","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""},{"name":"b","action":"ok","after":"a","key":"","value":"","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""}]}')" = "400" ]
[ "$(postcode /v1/workflows '{"name":"ghost","steps":[{"name":"a","action":"teleport","after":"","key":"","value":"","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""}]}')" = "400" ]
[ "$(code /v1/workflows/missing)" = "404" ]

say "a run is seeded from the definition"
R=$(post /v1/runs '{"workflow":"order","input":"A-42"}')
ID=$(echo "$R" | jq -r .id)
[ "$(echo "$R" | jq -r .status)" = "pending" ]
[ "$(echo "$R" | jq -r '.steps | length')" = "4" ]
[ "$(echo "$R" | jq -r '.steps[0].status')" = "pending" ]
[ "$(postcode /v1/runs '{"workflow":"missing"}')" = "404" ]
[ "$(postcode /v1/runs '{"workflow":""}')" = "400" ]

say "one tick runs the wave, a flaky step lands in backoff"
T1=$(post /v1/ticks '{"limit":10}')
[ "$(echo "$T1" | jq -r .claimed)" = "1" ]
[ "$(echo "$T1" | jq -r .advanced)" = "2" ]
V=$(get "/v1/runs/$ID")
[ "$(echo "$V" | jq -r .status)" = "running" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="validate") | .status')" = "done" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="charge") | .status')" = "waiting" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="charge") | .attempts')" = "1" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="charge") | .error')" = "flaky failure on attempt 1" ]

say "the retry succeeds, the delayed step waits for its own clock"
sleep 0.5
T2=$(post /v1/ticks '{"limit":10}')
[ "$(echo "$T2" | jq -r .claimed)" = "1" ]
V=$(get "/v1/runs/$ID")
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="charge") | .status')" = "done" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="charge") | .attempts')" = "2" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="ship") | .status')" = "waiting" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="ship") | .dueAt != null')" = "true" ]

say "the timer fires and the run completes with its variables"
sleep 0.5
T3=$(post /v1/ticks '{"limit":10}')
[ "$(echo "$T3" | jq -r .completed)" = "1" ]
V=$(get "/v1/runs/$ID")
[ "$(echo "$V" | jq -r .status)" = "done" ]
[ "$(echo "$V" | jq -r '.steps[] | select(.name=="notify") | .output')" = "shipped A-42" ]
[ "$(echo "$V" | jq -r .vars | jq -r .note)" = "shipped A-42" ]
[ "$(echo "$V" | jq -r .nextAt)" = "null" ]
[ "$(echo "$V" | jq -r '.attempts')" = "5" ]
[ "$(get '/v1/runs?status=done' | jq -r '.items | length')" = "1" ]
[ "$(code '/v1/runs?status=waiting')" = "400" ]
[ "$(code '/v1/runs?limit=0')" = "400" ]

say "a permanent failure unwinds completed steps in reverse"
post /v1/workflows '{"name":"checkout","steps":[{"name":"reserve","action":"ok","after":"","key":"","value":"reserved","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":"release"},{"name":"pay","action":"fail","after":"reserve","key":"","value":"card declined","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""}]}' >/dev/null
FID=$(post /v1/runs '{"workflow":"checkout"}' | jq -r .id)
post /v1/ticks '{"limit":10}' >/dev/null
F=$(get "/v1/runs/$FID")
[ "$(echo "$F" | jq -r .status)" = "failed" ]
[ "$(echo "$F" | jq -r .error)" = "card declined" ]
[ "$(echo "$F" | jq -r '.steps[] | select(.name=="pay") | .status')" = "failed" ]
[ "$(echo "$F" | jq -r '.steps[] | select(.name=="~reserve") | .status')" = "done" ]
[ "$(echo "$F" | jq -r '.steps[] | select(.name=="~reserve") | .kind')" = "compensate" ]

say "cancel rolls a waiting run back instead of leaving it parked"
post /v1/workflows '{"name":"long","steps":[{"name":"hold","action":"ok","after":"","key":"","value":"held","delayMs":5000,"retry":0,"backoffMs":0,"failFirst":0,"compensate":"release"},{"name":"after","action":"ok","after":"hold","key":"","value":"late","delayMs":0,"retry":0,"backoffMs":0,"failFirst":0,"compensate":""}]}' >/dev/null
CID=$(post /v1/runs '{"workflow":"long"}' | jq -r .id)
post /v1/ticks '{"limit":10}' >/dev/null
[ "$(get "/v1/runs/$CID" | jq -r .status)" = "running" ]
C=$(post "/v1/runs/$CID/cancel" '{}')
[ "$(echo "$C" | jq -r .status)" = "cancelled" ]
[ "$(echo "$C" | jq -r '.steps[] | select(.name=="after") | .status')" = "pending" ]
[ "$(postcode "/v1/runs/$CID/cancel" '{}')" = "409" ]
[ "$(postcode "/v1/runs/00000000-0000-0000-0000-000000000000/cancel" '{}')" = "404" ]
[ "$(code /v1/runs/00000000-0000-0000-0000-000000000000)" = "404" ]

say "two ticks race for one claim; only one advances the run"
RID=$(post /v1/runs '{"workflow":"long"}' | jq -r .id)
curl -sS -X POST "$BASE/v1/ticks" -H 'content-type: application/json' -d '{"limit":10}' > /tmp/flow-a.json &
PA=$!
curl -sS -X POST "$BASE/v1/ticks" -H 'content-type: application/json' -d '{"limit":10}' > /tmp/flow-b.json &
PB=$!
wait "$PA" "$PB"
CA=$(jq -r .claimed /tmp/flow-a.json)
CB=$(jq -r .claimed /tmp/flow-b.json)
[ "$((CA + CB))" = "1" ]
[ "$(get "/v1/runs/$RID" | jq -r '.steps[] | select(.name=="hold") | .attempts')" = "0" ]
[ "$(get "/v1/runs/$RID" | jq -r '.steps[] | select(.name=="hold") | .status')" = "waiting" ]
post "/v1/runs/$RID/cancel" '{}' >/dev/null

say "a schedule spawns one run per period"
post /v1/schedules '{"name":"nightly","workflow":"order","everySeconds":1}' >/dev/null
[ "$(postcode /v1/schedules '{"name":"nightly","workflow":"order","everySeconds":1}')" = "409" ]
[ "$(postcode /v1/schedules '{"name":"zero","workflow":"order","everySeconds":0}')" = "400" ]
[ "$(postcode /v1/schedules '{"name":"ghost","workflow":"missing","everySeconds":5}')" = "404" ]
[ "$(get /v1/schedules | jq -r 'length')" = "1" ]
BEFORE=$(get /v1/health | jq -r .runs)
sleep 1.3
S1=$(post /v1/ticks '{"limit":10}')
[ "$(echo "$S1" | jq -r .spawned)" = "1" ]
[ "$(get /v1/health | jq -r .runs)" = "$((BEFORE + 1))" ]
S2=$(post /v1/ticks '{"limit":10}')
[ "$(echo "$S2" | jq -r .spawned)" = "0" ]

say "stats and limits"
[ "$(postcode /v1/ticks '{"limit":0}')" = "400" ]
[ "$(get /v1/health | jq -r .workflows)" = "3" ]
RUNS=$(get /v1/health | jq -r .runs)
[ "$RUNS" -ge 3 ]

say "PASS"
