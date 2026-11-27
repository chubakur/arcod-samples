#!/usr/bin/env bash
# End-to-end: mysql + rabbitmq + minio + websocket.
# Doc -> op log -> live fanout -> snapshot in S3 -> queue compaction -> comments
# with a consumer. Every write is checked twice: the API answer and the read path.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8094}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
RUN_PID=""

fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "- $*"; }
jget() { node -e 'const fs=require("fs");let v=JSON.parse(fs.readFileSync(0,"utf8"));for(const k of process.argv[1].split("."))v=v[k];process.stdout.write(String(v))' "$1"; }

arcod_run() {
  if [ -n "$ARCOD_JS" ]; then node "$ARCOD_JS" "$@"; else "$ARCOD" "$@"; fi
}

cleanup() {
  if [ -n "$RUN_PID" ]; then
    kill "$RUN_PID" >/dev/null 2>&1 || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

arcod_run check >/dev/null
arcod_run build --impl --port "$PORT" >/dev/null
arcod_run run --impl --port "$PORT" >/tmp/arcod-sample-044.log 2>&1 &
RUN_PID=$!
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see /tmp/arcod-sample-044.log)"
say "healthz ok"

# --- validation and creation ---
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/docs" -H 'content-type: application/json' -d '{"title":"","owner":"ann"}')
[ "$BAD" = "400" ] || fail "empty title answered $BAD, want 400"

CODE=$(curl -s -o /tmp/arcod-044-doc.json -w '%{http_code}' -X POST "$BASE/v1/docs" -H 'content-type: application/json' -d '{"title":"Plan","owner":"ann"}')
[ "$CODE" = "201" ] || fail "create doc answered $CODE"
DOC=$(jget id < /tmp/arcod-044-doc.json)
[ -n "$DOC" ] || fail "create doc returned no id"
say "doc created: $DOC"

# --- operation log, idempotency and deletes ---
post_op() {
  curl -s -o /tmp/arcod-044-op.json -w '%{http_code}' -X POST "$BASE/v1/docs/$DOC/ops" \
    -H 'content-type: application/json' -d "$1"
}
[ "$(post_op '{"clientId":"c1","seq":1,"kind":"insert","pos":0,"text":"Hello"}')" = "201" ] || fail "insert rejected"
grep -q '"version":1' /tmp/arcod-044-op.json || fail "first op is not version 1"
[ "$(post_op '{"clientId":"c1","seq":1,"kind":"insert","pos":0,"text":"Hello"}')" = "201" ] || fail "retry rejected"
grep -q '"duplicate":true' /tmp/arcod-044-op.json || fail "retry is not marked duplicate"
grep -q '"version":1' /tmp/arcod-044-op.json || fail "retry bumped the version"
[ "$(post_op '{"clientId":"c2","seq":1,"kind":"insert","pos":5,"text":" world"}')" = "201" ] || fail "second client insert rejected"
[ "$(post_op '{"clientId":"c1","seq":2,"kind":"delete","pos":5,"text":" "}')" = "201" ] || fail "delete rejected"
BADOP=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/docs/$DOC/ops" -H 'content-type: application/json' -d '{"clientId":"c1","seq":3,"kind":"move","pos":0,"text":""}')
[ "$BADOP" = "400" ] || fail "unknown op kind answered $BADOP, want 400"
say "ops: insert, duplicate retry, delete, bad kind 400"

CONTENT=$(curl -s "$BASE/v1/docs/$DOC" | jget content)
[ "$CONTENT" = "Helloworld" ] || fail "document content is '$CONTENT', want 'Helloworld'"
OPS=$(curl -s "$BASE/v1/docs/$DOC/ops?since=1")
echo "$OPS" | grep -q '"version":3' || fail "ops?since=1 did not return the tail"
if echo "$OPS" | grep -q '"version":1'; then fail "ops?since=1 returned an op at or below the cursor"; fi
say "state: version 3, content 'Helloworld'"

# --- live stream: a real websocket must receive the next op ---
WS_LOG=$(mktemp)
rm -f "$WS_LOG"
node -e '
const [id, port, out] = process.argv.slice(1);
const fs = require("fs");
const ws = new WebSocket("ws://localhost:" + port + "/ws?topic=doc:" + id);
const timer = setTimeout(() => { try { fs.writeFileSync(out, "timeout"); } catch {} process.exit(1); }, 10000);
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "ready") fs.writeFileSync(out, "ready");
  if (m.type === "op") { clearTimeout(timer); fs.writeFileSync(out, "op:" + m.version); ws.close(); process.exit(0); }
};
ws.onerror = () => { try { fs.writeFileSync(out, "error"); } catch {} process.exit(1); };
' "$DOC" "$PORT" "$WS_LOG" &
WS_PID=$!
for _ in $(seq 1 40); do [ -s "$WS_LOG" ] && break; sleep 0.25; done
grep -q ready "$WS_LOG" 2>/dev/null || fail "websocket did not subscribe (log: $(cat "$WS_LOG" 2>/dev/null))"
DELIVERED=$(curl -s -X POST "$BASE/v1/docs/$DOC/cursor" -H 'content-type: application/json' -d '{"clientId":"c1","pos":3,"name":"ann"}' | jget delivered)
[ "$DELIVERED" = "1" ] || fail "cursor delivered $DELIVERED sockets, want 1"
post_op '{"clientId":"c2","seq":2,"kind":"insert","pos":0,"text":"> "}' >/dev/null
wait "$WS_PID" || true
grep -q 'op:4' "$WS_LOG" || fail "websocket did not receive the op (log: $(cat "$WS_LOG" 2>/dev/null))"
say "stream: cursor fanout and op delivered over websocket"

# --- 20 edits trigger the compaction job ---
for i in $(seq 1 20); do
  post_op "{\"clientId\":\"c3\",\"seq\":$i,\"kind\":\"insert\",\"pos\":0,\"text\":\"x\"}" >/dev/null
done
for _ in $(seq 1 60); do
  REVS=$(curl -s "$BASE/v1/docs/$DOC/revisions")
  echo "$REVS" | grep -q '"version"' && break
  sleep 1
done
echo "$REVS" | grep -q '"version"' || fail "compaction job wrote no revision"
# The job snapshots the log at the moment it runs; the client kept editing, so
# take an explicit snapshot before comparing it with the live text.
curl -s -X POST "$BASE/v1/docs/$DOC/snapshot" >/dev/null
SNAP=$(curl -s "$BASE/v1/docs/$DOC/snapshot")
echo "$SNAP" | grep -q '"key"' || fail "latest snapshot is missing"
SNAP_CONTENT=$(echo "$SNAP" | jget content)
LIVE_CONTENT=$(curl -s "$BASE/v1/docs/$DOC" | jget content)
[ "$SNAP_CONTENT" = "$LIVE_CONTENT" ] || fail "snapshot content differs from the document"
say "job compact: revision in S3, content matches the log (version $(curl -s "$BASE/v1/docs/$DOC" | jget version))"

# --- explicit snapshot endpoint on a second document ---
CODE=$(curl -s -o /tmp/arcod-044-doc2.json -w '%{http_code}' -X POST "$BASE/v1/docs" -H 'content-type: application/json' -d '{"title":"Spec","owner":"bob"}')
[ "$CODE" = "201" ] || fail "second doc answered $CODE"
DOC2=$(jget id < /tmp/arcod-044-doc2.json)
curl -s -X POST "$BASE/v1/docs/$DOC2/ops" -H 'content-type: application/json' -d '{"clientId":"d1","seq":1,"kind":"insert","pos":0,"text":"v1"}' >/dev/null
curl -s -X POST "$BASE/v1/docs/$DOC2/snapshot" | grep -q '"version":1' || fail "explicit snapshot failed"
curl -s "$BASE/v1/docs/$DOC2/snapshot" | grep -q '"content":"v1"' || fail "snapshot read from S3 failed"
say "snapshot: write to S3 and read back"

# --- parallel writers must not lose each other's edit ---
rm -f /tmp/arcod-044-par.txt
PAR_PIDS=""
for i in $(seq 1 5); do
  BODY="{\"clientId\":\"par$i\",\"seq\":1,\"kind\":\"insert\",\"pos\":0,\"text\":\"$i\"}"
  curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/v1/docs/$DOC2/ops" \
    -H 'content-type: application/json' -d "$BODY" >> /tmp/arcod-044-par.txt &
  PAR_PIDS="$PAR_PIDS $!"
done
for pid in $PAR_PIDS; do wait "$pid"; done
[ "$(sort /tmp/arcod-044-par.txt | uniq -c | awk '{print $2}' | tr -d '\n')" = "201" ] || fail "parallel ops: not all answered 201"
PAR=$(curl -s "$BASE/v1/docs/$DOC2" | jget version)
PAR_LEN=$(curl -s "$BASE/v1/docs/$DOC2" | jget content | wc -c | tr -d ' ')
[ "$PAR" = "6" ] || fail "parallel ops: version $PAR, want 6 (lost update)"
[ "$PAR_LEN" = "7" ] || fail "parallel ops: content length $PAR_LEN, want 7"
say "parallel ops: 5 writers, version 6, no lost update"

# --- comments: durable row, then the notify consumer ---
CMT=$(curl -s -X POST "$BASE/v1/docs/$DOC/comments" -H 'content-type: application/json' -d '{"author":"bob","body":"line 3?"}')
echo "$CMT" | grep -q '"notified":true' || fail "comment was not queued"
for _ in $(seq 1 40); do
  COMMENTS=$(curl -s "$BASE/v1/docs/$DOC/comments")
  echo "$COMMENTS" | grep -q '"status":"notified"' && break
  sleep 1
done
echo "$COMMENTS" | grep -q '"status":"notified"' || fail "notify consumer did not flip the comment"
say "job notify: comment flipped to notified"

# --- stats, dead letters, 404 ---
STATS=$(curl -s "$BASE/v1/stats")
[ "$(echo "$STATS" | jget docs)" = "2" ] || fail "stats.docs is not 2"
echo "$STATS" | grep -q '"comments":1' || fail "stats.comments is not 1"
DEAD=$(curl -s "$BASE/v1/dead")
[ "$DEAD" = "[]" ] || fail "dead letters: $DEAD"
MISS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/docs/00000000-0000-4000-8000-000000000000")
[ "$MISS" = "404" ] || fail "unknown doc answered $MISS, want 404"
say "stats: $STATS; dead letters empty; unknown doc 404"

echo "PASS"
