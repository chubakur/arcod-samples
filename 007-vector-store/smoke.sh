#!/usr/bin/env bash
# End-to-end smoke: collections, embeddings, an untrained (exact) query, a
# trained inverted-file query, metadata filters, replacement, delete, stats,
# drop and the 404/400 edges. Ends with PASS.
set -euo pipefail
cd "$(dirname "$0")"

ARCOD="${ARCOD:-arcod}"
PORT="${PORT:-8097}"
BASE="http://localhost:${PORT}"
LOG="${LOG:-/tmp/arcod-vector-store.log}"

cleanup() {
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
post() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$BASE$1"; }

# Start from nothing: no containers, no old build, no stale index.
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
[ "$(curl -s "$BASE/v1/health" | jq -r .collections)" = "0" ]

say "create a collection"
C=$(post /v1/collections '{"name":"docs","dim":16,"metric":"cosine","nlist":2,"nprobe":2}')
[ "$(echo "$C" | jq -r .dim)" = "16" ]
[ "$(echo "$C" | jq -r .trained)" = "false" ]

say "a second create is a conflict, a zero dim is invalid"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/collections" -H 'content-type: application/json' -d '{"name":"docs","dim":16}')" = "409" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/collections" -H 'content-type: application/json' -d '{"name":"bad","dim":0}')" = "400" ]

say "batch upsert three text documents"
B=$(post /v1/vectors/batch '{"collection":"docs","vectors":[
 {"id":"d1","values":[],"meta":"{\"kind\":\"db\"}","text":"a vector database stores embeddings and answers nearest neighbour queries"},
 {"id":"d2","values":[],"meta":"{\"kind\":\"web\"}","text":"a web server answers http requests with json"},
 {"id":"d3","values":[],"meta":"{\"kind\":\"db\"}","text":"the postal database keeps shipping addresses"}]}')
[ "$(echo "$B" | jq -r .inserted)" = "3" ]
[ "$(echo "$B" | jq -r '.ids | length')" = "3" ]

say "an untrained collection answers exactly and says so"
Q0=$(post /v1/query '{"collection":"docs","text":"vector nearest neighbour search","k":3}')
[ "$(echo "$Q0" | jq -r .exact)" = "true" ]
[ "$(echo "$Q0" | jq -r '.probedSlots | length')" = "0" ]
[ "$(echo "$Q0" | jq -r '.scanned')" = "3" ]

say "build the inverted file"
R=$(post /v1/index '{"collection":"docs"}')
[ "$(echo "$R" | jq -r .centroids)" = "2" ]
[ "$(echo "$R" | jq -r .assigned)" = "3" ]
[ "$(echo "$R" | jq -r .slots)" = "3" ]

say "a trained query probes slots and ranks the right document first"
Q=$(post /v1/query '{"collection":"docs","text":"vector nearest neighbour search","k":3}')
[ "$(echo "$Q" | jq -r .exact)" = "false" ]
[ "$(echo "$Q" | jq -r .hits[0].id)" = "d1" ]
[ "$(echo "$Q" | jq -r '.probedSlots | length')" = "2" ]
[ "$(echo "$Q" | jq -r '.hits[0].score > .hits[1].score')" = "true" ]

say "metadata filters are part of the query"
F=$(post /v1/query '{"collection":"docs","text":"database","k":5,"filter":"kind=db"}')
[ "$(echo "$F" | jq -r '.hits | length')" = "2" ]
[ "$(echo "$F" | jq -r '[.hits[].meta] | map(contains("\"db\"")) | all')" = "true" ]
[ "$(post /v1/query '{"collection":"docs","text":"database","k":1,"filter":"kind in (web, db)"}' | jq -r '.hits | length')" = "1" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/query" -H 'content-type: application/json' -d '{"collection":"docs","text":"x","k":1,"filter":"oops"}')" = "400" ]

say "exact=true skips the index"
E=$(post /v1/query '{"collection":"docs","text":"database","k":3,"exact":true}')
[ "$(echo "$E" | jq -r .exact)" = "true" ]
[ "$(echo "$E" | jq -r '.probedSlots | length')" = "0" ]

say "replacing a vector moves its version and keeps it findable"
U=$(post /v1/vectors '{"collection":"docs","id":"d2","values":[],"meta":"{\"kind\":\"web\"}","text":"a web server answers http requests and serves json over tls"}')
[ "$(echo "$U" | jq -r .version)" = "2" ]
[ "$(echo "$U" | jq -r .inserted)" = "false" ]
[ "$(curl -s "$BASE/v1/collections/docs/vectors/d2" | jq -r .version)" = "2" ]

say "delete removes the vector and its slot"
D=$(curl -s -X DELETE "$BASE/v1/collections/docs/vectors/d3")
[ "$(echo "$D" | jq -r .deleted)" = "true" ]
[ "$(echo "$D" | jq -r .slots)" = "1" ]
[ "$(code /v1/collections/docs/vectors/d3)" = "404" ]
S=$(curl -s "$BASE/v1/collections/docs/stats")
[ "$(echo "$S" | jq -r .vectors)" = "2" ]
[ "$(echo "$S" | jq -r .scannedVectors)" = "2" ]
[ "$(echo "$S" | jq -r .scannedSlots)" = "2" ]

say "duplicate vector ids inside one batch are a client bug"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/vectors/batch" -H 'content-type: application/json' -d '{"collection":"docs","vectors":[{"id":"x","values":[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"meta":"{}","text":""},{"id":"x","values":[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],"meta":"{}","text":""}]}')" = "400" ]

say "drop takes vectors, slots and centroids with it"
X=$(curl -s -X DELETE "$BASE/v1/collections/docs")
[ "$(echo "$X" | jq -r .dropped)" = "true" ]
[ "$(echo "$X" | jq -r .vectors)" = "2" ]
[ "$(code /v1/collections/docs)" = "404" ]
[ "$(curl -s "$BASE/v1/health" | jq -r .collections)" = "0" ]

say "PASS"
