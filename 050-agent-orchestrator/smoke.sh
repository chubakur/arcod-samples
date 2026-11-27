#!/usr/bin/env bash
# 050-agent-orchestrator: an LLM agent loop with a closed tool list, a token
# budget, durable steps, traces in S3 and per-run cost accounting.
# Five external systems: postgres, redis, minio, an OpenAI-compatible model and
# a tool sandbox (the last two run on the host, mocks/upstream.mjs).
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8097}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-050.log
MOCKLOG=/tmp/arcod-050-mock.log
BODY=/tmp/arcod-050-body.json
COMPOSE=.arcod/build/docker-compose.yml

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:-$BODY}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" >/dev/null 2>&1 || true
  docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A leftover mock from an earlier run would answer with stale counters.
pkill -f 'mocks/upstream.mjs' >/dev/null 2>&1 || true

json_post() { curl -sS -o "$BODY" -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
json_get() { curl -sS -o "$BODY" -w '%{http_code}' "$BASE$1"; }
post() { json_post "$1" "$2" >/dev/null; cat "$BODY"; }
getj() { json_get "$1" >/dev/null; cat "$BODY"; }

wait_status() {
  local id="$1" want="$2"
  for _ in $(seq 1 120); do
    local s
    s=$(getj "/v1/runs/$id" | jq -r .run.status)
    case "$s" in
      succeeded|failed|budget_exceeded|cancelled) [ "$s" = "$want" ] && return 0; return 1 ;;
    esac
    sleep 0.25
  done
  return 1
}

start_run() { post "/v1/agents/$1/runs" "$2"; }

docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true

say "check"
$ARCOD check >/dev/null

say "build"
$ARCOD build --impl --port "$PORT" >/dev/null

say "upstreams: model and tool sandbox on the host"
node mocks/upstream.mjs >"$MOCKLOG" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  curl -fsS http://localhost:9099/stats >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS http://localhost:9099/stats >/dev/null || { cat "$MOCKLOG"; fail "mock model did not start"; }
curl -fsS http://localhost:9098/healthz >/dev/null || { cat "$MOCKLOG"; fail "mock tools did not start"; }

say "run"
$ARCOD run --impl --port "$PORT" >"$LOG" 2>&1 &
RUN_PID=$!
for _ in $(seq 1 180); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -80 "$LOG"; fail "service did not start"; }

say "agents: register, duplicate is 409, empty prompt is 400"
[ "$(json_post /v1/agents '{"name":"support","systemPrompt":"You answer questions about orders.","tools":"lookup_order,refund_order,sleep","tokenBudget":4000,"maxSteps":6}')" = "201" ] || fail "createAgent must be 201"
AID=$(J .id); [ -n "$AID" ] || fail "agent id missing"
[ "$(J .tools)" = "lookup_order,refund_order,sleep" ] || fail "tool allow-list not stored"
[ "$(json_post /v1/agents '{"name":"support","systemPrompt":"duplicate"}')" = "409" ] || fail "duplicate agent must be 409"
[ "$(json_post /v1/agents '{"name":"no-prompt"}')" = "400" ] || fail "empty prompt must be 400"
[ "$(getj /v1/agents | jq 'length')" = "1" ] || fail "one agent expected"

say "run 1: model calls a tool, the answer comes from the observation"
[ "$(json_post "/v1/agents/$AID/runs" '{"input":"Where is order 1042?","clientRef":"c-1"}')" = "201" ] || fail "startRun must be 201"
R1=$(J .id); [ "$(J .status)" = "queued" ] || fail "a fresh run must be queued"
wait_status "$R1" succeeded || { getj "/v1/runs/$R1"; fail "run 1 did not succeed"; }
DETAIL=$(getj "/v1/runs/$R1")
[ "$(printf '%s' "$DETAIL" | jq -r .run.answer)" = "Order 1042 is shipped; total 129.00 RUB." ] || fail "answer must carry the tool observation"
[ "$(printf '%s' "$DETAIL" | jq -r .run.toolCalls)" = "1" ] || fail "one tool call expected"
[ "$(printf '%s' "$DETAIL" | jq -r '.steps | map(.kind) | join(",")')" = "tool,final" ] || fail "steps must be tool,final"
[ "$(printf '%s' "$DETAIL" | jq -r .run.tokens)" -gt 0 ] || fail "tokens must be counted"

say "run 1: trace is a real object in S3"
TRACE=$(getj "/v1/runs/$R1/trace")
[ "$(printf '%s' "$TRACE" | jq -r .key)" = "runs/$R1.json" ] || fail "trace key mismatch"
[ "$(printf '%s' "$TRACE" | jq -r .content | jq -r .status)" = "succeeded" ] || fail "trace status mismatch"
[ "$(printf '%s' "$TRACE" | jq -r .content | grep -c 'lookup_order')" -ge 1 ] || fail "trace must name the tool call"

say "idempotency: the same clientRef returns the same run"
[ "$(json_post "/v1/agents/$AID/runs" '{"input":"Where is order 1042?","clientRef":"c-1"}')" = "201" ] || fail "repeat must answer 201 (POST has one status, #56)"
[ "$(J .id)" = "$R1" ] || fail "repeat must return the original run"
[ "$(getj /v1/runs | jq 'length')" = "1" ] || fail "repeat must not create a second run"

say "run 2: refund tool, amount from the observation"
start_run "$AID" '{"input":"Refund order 1042 please"}' >/dev/null
R2=$(J .id)
wait_status "$R2" succeeded || fail "run 2 did not succeed"
[ "$(getj "/v1/runs/$R2" | jq -r .run.answer | grep -c '129.00 RUB')" = "1" ] || fail "refund answer must quote the amount"

say "run 3: a tool outside the allow-list fails the run, no HTTP call"
start_run "$AID" '{"input":"Use the banned tool now"}' >/dev/null
R3=$(J .id)
wait_status "$R3" failed || fail "run 3 must fail"
D3=$(getj "/v1/runs/$R3")
[ "$(printf '%s' "$D3" | jq -r .run.error)" = "tool not allowed: drop_database" ] || fail "denied tool must be named"
[ "$(printf '%s' "$D3" | jq -r '.steps[0].kind')" = "denied" ] || fail "denied step must be recorded"

say "run 4: a failing tool stops the run and keeps the error"
start_run "$AID" '{"input":"broken order lookup"}' >/dev/null
R4=$(J .id)
wait_status "$R4" failed || fail "run 4 must fail"
D4=$(getj "/v1/runs/$R4")
[ "$(printf '%s' "$D4" | jq -r .run.error | grep -c 'unreachable')" = "1" ] || fail "tool failure must be reported"
[ "$(printf '%s' "$D4" | jq -r '.steps[0].kind')" = "error" ] || fail "error step must be recorded"

say "budget: a looping model is stopped by the token budget"
[ "$(json_post /v1/agents '{"name":"looper","systemPrompt":"Loop forever.","tools":"lookup_order","maxSteps":8,"tokenBudget":200}')" = "201" ] || fail "looper must be 201"
BID=$(J .id)
start_run "$BID" '{"input":"loop until the budget dies"}' >/dev/null
RB=$(J .id)
wait_status "$RB" budget_exceeded || { getj "/v1/runs/$RB"; fail "run must hit budget_exceeded"; }
DB=$(getj "/v1/runs/$RB")
[ "$(printf '%s' "$DB" | jq -r .run.tokens)" -ge 200 ] || fail "budget must be crossed"
[ "$(printf '%s' "$DB" | jq -r '.steps | map(.kind) | join(",")')" = "tool,tool" ] || fail "two tool steps expected before the stop"

say "cancel: 200 while running, the runner stops between steps"
[ "$(json_post /v1/agents '{"name":"slowpoke","systemPrompt":"Do things slowly.","tools":"sleep","tokenBudget":4000}')" = "201" ] || fail "slowpoke must be 201"
SID=$(J .id)
start_run "$SID" '{"input":"slow task please"}' >/dev/null
RC=$(J .id)
for _ in $(seq 1 40); do
  [ "$(getj "/v1/runs/$RC" | jq -r .run.status)" = "running" ] && break
  sleep 0.1
done
[ "$(json_post "/v1/runs/$RC/cancel" '{}')" = "200" ] || fail "cancel must answer 200"
[ "$(J .cancelRequested)" = "true" ] || fail "cancel must set the flag"
wait_status "$RC" cancelled || { getj "/v1/runs/$RC"; fail "slow run must end cancelled"; }
[ "$(json_post "/v1/runs/$RC/cancel" '{}')" = "409" ] || fail "cancelling a finished run must be 409"

say "cancel: an early cancel also lands, whether the runner started or not"
start_run "$SID" '{"input":"slow second"}' >/dev/null
RQ=$(J .id)
[ "$(json_post "/v1/runs/$RQ/cancel" '{}')" = "200" ] || fail "early cancel must answer 200"
wait_status "$RQ" cancelled || fail "early run must be cancelled"
[ "$(getj "/v1/runs/$RQ" | jq -r .run.answer)" = "" ] || fail "cancelled run must have no answer"

say "stats: counters, tokens, tool calls and billed amount"
STATS=$(getj /v1/stats)
[ "$(printf '%s' "$STATS" | jq -r .runs)" = "7" ] || fail "seven runs expected"
[ "$(printf '%s' "$STATS" | jq -r .succeeded)" = "2" ] || fail "two succeeded expected"
[ "$(printf '%s' "$STATS" | jq -r .failed)" = "2" ] || fail "two failed expected"
[ "$(printf '%s' "$STATS" | jq -r .budgetExceeded)" = "1" ] || fail "one budget run expected"
[ "$(printf '%s' "$STATS" | jq -r .cancelled)" = "2" ] || fail "two cancelled expected"
[ "$(printf '%s' "$STATS" | jq -r .toolCalls)" -ge 4 ] || fail "tool calls must be summed"
[ "$(printf '%s' "$STATS" | jq -r .amount)" -gt 0 ] || fail "invoice consumer must bill something"
[ "$(getj '/v1/runs?status=failed' | jq 'length')" = "2" ] || fail "status filter must work"

say "sweep: a runner that died is marked failed, and a second sweep is a no-op"
docker compose -f "$COMPOSE" exec -T db psql -U arcod -d arcod -c \
  "update run set status='running', \"startedAt\"='2020-01-01T00:00:00Z' where id='$R2';" >/dev/null
[ "$(post /v1/sweep '{"now":"2026-11-27T14:00:00Z"}' | jq -r .stale)" = "1" ] || fail "stale run must be swept"
[ "$(post /v1/sweep '{"now":"2026-11-27T14:00:00Z"}' | jq -r .stale)" = "0" ] || fail "second sweep must be a no-op"
[ "$(getj "/v1/runs/$R2" | jq -r .run.status)" = "failed" ] || fail "swept run must be failed"

say "errors: 404 for an unknown run, 400 for empty input, empty dead letters"
[ "$(json_get /v1/runs/does-not-exist)" = "404" ] || fail "unknown run must be 404"
[ "$(json_post "/v1/agents/$AID/runs" '{"input":"  "}')" = "400" ] || fail "empty input must be 400"
[ "$(getj /v1/dead | jq 'length')" = "0" ] || fail "dead letters must be empty"

say "upstream counters: the model and the sandbox were really called"
MOCK=$(curl -fsS http://localhost:9099/stats)
[ "$(printf '%s' "$MOCK" | jq -r .llmCalls)" -ge 6 ] || fail "model calls missing"
[ "$(printf '%s' "$MOCK" | jq -r .toolCalls)" -ge 4 ] || fail "tool calls missing"

printf '\nPASS 050-agent-orchestrator: 5 external systems (postgres, redis, minio, model, tools), 2 consumers, %s\n' "$BASE"
