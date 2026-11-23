#!/usr/bin/env bash
# End-to-end: mysql + redis(kv) + redis(queue) + minio + external webhook.
# Upload -> S3 -> two consumers -> renditions -> ready -> webhook. A corrupt
# source burns the retry budget and parks the video as failed; the retry route
# refuses a ready video with 409.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8093}"
HOOK_PORT="${HOOK_PORT:-9098}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
HOOK_LOG=/tmp/arcod-014-hook.jsonl
MOCK_PID=""

fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "- $*"; }

cleanup() {
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
rm -f "$HOOK_LOG"

PORT="$HOOK_PORT" HOOK_LOG="$HOOK_LOG" node mock/hook.mjs >/tmp/arcod-014-mock.log 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 40); do
  curl -fsS "http://localhost:${HOOK_PORT}/healthz" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fsS "http://localhost:${HOOK_PORT}/healthz" >/dev/null || fail "hook mock is not up"

"$ARCOD" check >/dev/null
"$ARCOD" build --impl --port "$PORT" >/dev/null
"$ARCOD" run --impl --port "$PORT" >/tmp/arcod-sample-014.log 2>&1 &
for _ in $(seq 1 150); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service is not up (see /tmp/arcod-sample-014.log)"
say "health: ok (service + mysql + redis queue + minio + webhook mock)"

wait_status() {
  local id="$1" want="$2"
  for _ in $(seq 1 80); do
    local got
    got=$(curl -fsS "$BASE/v1/videos/$id" | jq -r .video.status)
    if [ "$got" = "$want" ]; then return 0; fi
    sleep 0.5
  done
  return 1
}

# 1. Upload: the bytes go to S3, the work goes to the queue, the answer is fast.
UP=$(curl -fsS -X POST "$BASE/v1/videos" -H 'content-type: application/json' \
  -d '{"title":"Launch teaser","owner":"acme","checksum":"sum-001","contentType":"video/mp4","durationSec":42,"body":"MP4-DATA-0123456789-abcdefghijklmnop"}')
VID=$(printf '%s' "$UP" | jq -r .id)
[ "$(printf '%s' "$UP" | jq -r .status)" = "queued" ] || fail "upload did not answer queued"
say "upload: $VID queued, sourceKey $(printf '%s' "$UP" | jq -r .sourceKey)"

# 2. The consumer finishes both presets and the webhook sees a ready video.
wait_status "$VID" ready || fail "video $VID never became ready"
VIEW=$(curl -fsS "$BASE/v1/videos/$VID")
[ "$(printf '%s' "$VIEW" | jq -r .ready)" = "2" ] || fail "expected 2 renditions"
[ "$(printf '%s' "$VIEW" | jq -r '.video.previewKey')" != "null" ] || fail "preview was not written"
say "consumer: 2 renditions, preview $(printf '%s' "$VIEW" | jq -r '.video.previewKey')"

# 3. The source and a rendition are readable through the service, not the bucket.
SRC=$(curl -fsS "$BASE/v1/videos/$VID/source" | jq -r .body)
[ "$SRC" = "MP4-DATA-0123456789-abcdefghijklmnop" ] || fail "source bytes differ: $SRC"
RID=$(printf '%s' "$VIEW" | jq -r '.renditions[0].id')
REND=$(curl -fsS "$BASE/v1/renditions/$RID/file" | jq -r .body)
case "$REND" in
  720p\|1280x720\|2400\|*|480p\|854x480\|900\|*) ;;
  *) fail "rendition body is not the derived payload: $REND" ;;
esac
say "blob: source and rendition round-trip through S3"

# 4. The webhook really left the process and carried the preview key.
for _ in $(seq 1 40); do
  [ -s "$HOOK_LOG" ] && break
  sleep 0.25
done
grep -q '"videoId":"'"$VID"'"' "$HOOK_LOG" || fail "webhook never received the ready event"
grep -q '"previewKey":"videos/' "$HOOK_LOG" || fail "webhook payload has no preview key"
say "webhook: ready event delivered"

# 5. A checksum is a promise: the same bytes are the same video.
CODE=$(curl -s -o /tmp/arcod-014-dup.json -w '%{http_code}' -X POST "$BASE/v1/videos" -H 'content-type: application/json' \
  -d '{"title":"Duplicate","owner":"acme","checksum":"sum-001","contentType":"video/mp4","durationSec":42,"body":"MP4-DATA-0123456789-abcdefghijklmnop"}')
[ "$CODE" = "409" ] || fail "duplicate checksum returned $CODE"
[ "$(jq -r .error /tmp/arcod-014-dup.json)" = "Conflict" ] || fail "duplicate did not answer Conflict"
say "guard: duplicate checksum rejected with 409"

# 6. Corrupt media burns the retry budget and parks the video as failed.
BAD=$(curl -fsS -X POST "$BASE/v1/videos" -H 'content-type: application/json' \
  -d '{"title":"Broken","owner":"acme","checksum":"sum-bad","contentType":"video/mp4","durationSec":5,"body":"CORRUPT-not-really-video"}')
BAD_ID=$(printf '%s' "$BAD" | jq -r .id)
wait_status "$BAD_ID" failed || fail "corrupt video $BAD_ID did not fail"
ATTEMPTS=$(curl -fsS "$BASE/v1/videos/$BAD_ID" | jq -r .video.attempts)
[ "$ATTEMPTS" -ge 2 ] || fail "corrupt video kept attempts=$ATTEMPTS, expected the retry budget to be spent"
say "consumer: corrupt source failed after $ATTEMPTS attempts"

# 7. Retry is refused for a ready video and accepted for a failed one.
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/videos/$VID/retry")
[ "$CODE" = "409" ] || fail "retry on a ready video returned $CODE"
RET=$(curl -fsS -X POST "$BASE/v1/videos/$BAD_ID/retry")
[ "$(printf '%s' "$RET" | jq -r .ok)" = "true" ] || fail "retry on a failed video was refused"
wait_status "$BAD_ID" failed || fail "retried video did not settle back to failed"
say "retry: ready -> 409, failed -> requeued and failed again (deterministic source)"

# 8. Stats agree with the rows the consumers wrote.
STATS=$(curl -fsS "$BASE/v1/stats")
TOTAL=$(printf '%s' "$STATS" | jq -r .total)
[ "$TOTAL" -ge 2 ] || fail "stats total is $TOTAL, expected at least 2"
[ "$(printf '%s' "$STATS" | jq -r .ready)" -ge 1 ] || fail "stats ready is 0"
[ "$(printf '%s' "$STATS" | jq -r .failed)" -ge 1 ] || fail "stats failed is 0"
say "stats: total=$TOTAL ready=$(printf '%s' "$STATS" | jq -r .ready) failed=$(printf '%s' "$STATS" | jq -r .failed)"

# 9. A sweep with nothing stale is a no-op, not an error.
SWEEP=$(curl -fsS -X POST "$BASE/v1/admin/sweep")
[ "$(printf '%s' "$SWEEP" | jq -r .ok)" = "true" ] || fail "sweep failed"
say "sweep: ok, queued=$(printf '%s' "$SWEEP" | jq -r .queued)"

echo "PASS"
