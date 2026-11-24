#!/usr/bin/env bash
# End-to-end: mysql + redis queue + s3 + a build runner on the compose network.
# Pipeline -> run -> execute consumer -> per-step logs and artifacts in S3 ->
# failure stops the pipeline, cancellation stops the next step, stats add up.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8095}"
RUNNER_PORT="${RUNNER_PORT:-9095}"
BASE="http://localhost:${PORT}"
RUNNER="http://localhost:${RUNNER_PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
RUN_PID=""
RUNNER_NAME="arcod-037-runner"

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
  docker rm -f "$RUNNER_NAME" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker rm -f "$RUNNER_NAME" >/dev/null 2>&1 || true
docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

arcod_run check >/dev/null
arcod_run build --impl --port "$PORT" >/dev/null
arcod_run run --impl --port "$PORT" >/tmp/arcod-sample-037.log 2>&1 &
RUN_PID=$!
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see /tmp/arcod-sample-037.log)"
say "health: ok (service + mysql + redis queue + s3)"

# The build runner joins the same compose network under the name the spec binds.
IMAGE=$(grep -m1 'image: arcod/ci-orchestrator-service' .arcod/build/docker-compose.yml | awk '{print $2}')
SERVICE_ID=$(docker compose -f .arcod/build/docker-compose.yml ps -q service)
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$SERVICE_ID")
[ -n "$IMAGE" ] && [ -n "$NETWORK" ] || fail "cannot find the service image/network"
docker run -d --name "$RUNNER_NAME" -p "${RUNNER_PORT}:9095" --network "$NETWORK" --network-alias runner \
  -v "$PWD/mock:/app" -w /app --entrypoint node "$IMAGE" runner.mjs >/dev/null
for _ in $(seq 1 30); do
  if curl -fsS "$RUNNER/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$RUNNER/healthz" >/dev/null || fail "runner did not start"
say "runner: ok (mock of the build machine API)"

# 1. A pipeline with three steps, then the same name again: Conflict.
BODY=$(jq -nc '{name:"sample", repo:"github.com/chubakur/demo", branch:"main", steps:[
  {name:"compile", command:"echo compiling main.arc"},
  {name:"test", command:"artifact report"},
  {name:"package", command:"echo packaging"}
]}')
CODE=$(curl -s -o /tmp/arcod-037-pipeline.json -w '%{http_code}' -X POST "$BASE/v1/pipelines" \
  -H 'content-type: application/json' -d "$BODY")
[ "$CODE" = "201" ] || fail "pipeline create answered $CODE"
PID=$(jq -r .pipeline.id /tmp/arcod-037-pipeline.json)
[ "$(jq -r '.steps | length' /tmp/arcod-037-pipeline.json)" = "3" ] || fail "want 3 steps"
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/pipelines" \
  -H 'content-type: application/json' -d "$BODY")
[ "$DUP" = "409" ] || fail "duplicate pipeline answered $DUP, want 409"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/pipelines" \
  -H 'content-type: application/json' -d '{"name":"empty","repo":"r","steps":[]}')
[ "$BAD" = "400" ] || fail "pipeline without steps answered $BAD, want 400"
say "pipeline: created with 3 steps; duplicate 409; empty steps 400"

# 2. Trigger, wait for the consumer, then read the log and the artifact from S3.
CODE=$(curl -s -o /tmp/arcod-037-run.json -w '%{http_code}' -X POST "$BASE/v1/pipelines/$PID/runs" \
  -H 'content-type: application/json' -d '{"ref":"main"}')
[ "$CODE" = "201" ] || fail "trigger answered $CODE"
RID=$(jq -r .id /tmp/arcod-037-run.json)
STATUS=""
for _ in $(seq 1 90); do
  VIEW=$(curl -fsS "$BASE/v1/runs/$RID")
  STATUS=$(echo "$VIEW" | jq -r .run.status)
  if [ "$STATUS" = "succeeded" ] || [ "$STATUS" = "failed" ]; then break; fi
  sleep 1
done
[ "$STATUS" = "succeeded" ] || fail "run stuck in $STATUS"
echo "$VIEW" | jq -e '[.steps[].status] == ["succeeded","succeeded","succeeded"]' >/dev/null \
  || fail "steps did not all succeed"
LOG=$(curl -fsS "$BASE/v1/runs/$RID/logs/1")
echo "$LOG" | jq -e '.body | contains("compiling main.arc")' >/dev/null || fail "log 1 has no stdout"
ARTS=$(curl -fsS "$BASE/v1/runs/$RID/artifacts")
echo "$ARTS" | jq -e '.total == 1 and (.items[0].name | contains("report"))' >/dev/null || fail "artifact row missing"
AID=$(echo "$ARTS" | jq -r .items[0].id)
AFILE=$(curl -fsS "$BASE/v1/artifacts/$AID")
echo "$AFILE" | jq -e '.body | contains("42 tests passed")' >/dev/null || fail "artifact body missing"
echo "$ARTS" | jq -e '.items[0].sha256 | length == 64' >/dev/null || fail "artifact sha256 missing"
say "run: succeeded, 3 step logs in S3, artifact downloaded back with a sha256"

# 3. A slow run: a second trigger is 409, cancellation stops the next step.
BODY2=$(jq -nc '{name:"slow-pipe", repo:"github.com/chubakur/demo", steps:[
  {name:"deploy", command:"slow deploy"},
  {name:"verify", command:"echo verify"}
]}')
curl -fsS -X POST "$BASE/v1/pipelines" -H 'content-type: application/json' -d "$BODY2" >/tmp/arcod-037-slow.json
SID=$(jq -r .pipeline.id /tmp/arcod-037-slow.json)
curl -fsS -X POST "$BASE/v1/pipelines/$SID/runs" -H 'content-type: application/json' -d '{"ref":"main"}' >/tmp/arcod-037-slow-run.json
SRID=$(jq -r .id /tmp/arcod-037-slow-run.json)
for _ in $(seq 1 30); do
  SSTATUS=$(curl -fsS "$BASE/v1/runs/$SRID" | jq -r .run.status)
  if [ "$SSTATUS" = "running" ]; then break; fi
  sleep 1
done
[ "$SSTATUS" = "running" ] || fail "slow run never reached running ($SSTATUS)"
BUSY=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/pipelines/$SID/runs" \
  -H 'content-type: application/json' -d '{"ref":"main"}')
[ "$BUSY" = "409" ] || fail "second trigger answered $BUSY, want 409"
CANCEL=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/runs/$SRID/cancel")
[ "$CANCEL" = "200" ] || [ "$CANCEL" = "201" ] || fail "cancel answered $CANCEL"
for _ in $(seq 1 30); do
  SVIEW=$(curl -fsS "$BASE/v1/runs/$SRID")
  SSTATUS=$(echo "$SVIEW" | jq -r .run.status)
  if [ "$SSTATUS" = "cancelled" ]; then break; fi
  sleep 1
done
[ "$SSTATUS" = "cancelled" ] || fail "run stuck in $SSTATUS after cancel"
echo "$SVIEW" | jq -e '[.steps[].status] == ["succeeded","cancelled"] or [.steps[].status] == ["failed","cancelled"]' >/dev/null \
  || fail "cancel did not stop the second step"
say "cancel: 409 for a concurrent trigger, second step stopped"

# 4. A failing step stops the pipeline; the rest is skipped, not failed.
BODY3=$(jq -nc '{name:"broken-pipe", repo:"github.com/chubakur/demo", steps:[
  {name:"build", command:"fail build"},
  {name:"publish", command:"echo publish"}
]}')
curl -fsS -X POST "$BASE/v1/pipelines" -H 'content-type: application/json' -d "$BODY3" >/tmp/arcod-037-broken.json
BID=$(jq -r .pipeline.id /tmp/arcod-037-broken.json)
curl -fsS -X POST "$BASE/v1/pipelines/$BID/runs" -H 'content-type: application/json' -d '{"ref":"main"}' >/tmp/arcod-037-broken-run.json
BRID=$(jq -r .id /tmp/arcod-037-broken-run.json)
for _ in $(seq 1 60); do
  BVIEW=$(curl -fsS "$BASE/v1/runs/$BRID")
  BSTATUS=$(echo "$BVIEW" | jq -r .run.status)
  if [ "$BSTATUS" = "failed" ] || [ "$BSTATUS" = "succeeded" ]; then break; fi
  sleep 1
done
[ "$BSTATUS" = "failed" ] || fail "failing run ended as $BSTATUS"
echo "$BVIEW" | jq -e '[.steps[].status] == ["failed","skipped"]' >/dev/null || fail "steps not failed+skipped"
echo "$BVIEW" | jq -e '.run.error | contains("exited 1")' >/dev/null || fail "run has no failure reason"
BLOG=$(curl -fsS "$BASE/v1/runs/$BRID/logs/1")
echo "$BLOG" | jq -e '.body | contains("compilation failed")' >/dev/null || fail "failed log lost stderr"
say "failure: step failed, next skipped, stderr kept in S3"

# 5. Stats and 404.
STATS=$(curl -fsS "$BASE/v1/stats")
echo "$STATS" | jq -e '.succeeded == 1 and .failed == 1 and .cancelled == 1 and .artifacts == 1' >/dev/null \
  || fail "stats do not add up: $STATS"
MISS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/runs/00000000-0000-4000-8000-000000000000")
[ "$MISS" = "404" ] || fail "unknown run answered $MISS, want 404"
DEAD=$(curl -fsS "$BASE/v1/dead")
echo "$DEAD" | jq -e 'length == 0' >/dev/null || fail "dead letter is not empty"
say "stats: 1 succeeded / 1 failed / 1 cancelled / 1 artifact; unknown run 404; dead letter empty"

say "PASS"
