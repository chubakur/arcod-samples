#!/usr/bin/env bash
# End-to-end smoke: index documents, rank them, filter by tags and phrases,
# replace a document (old terms must disappear), paginate, suggest, delete and
# prove that the counters and 404s agree. Ends with PASS.
set -euo pipefail
cd "$(dirname "$0")"

ARCOD="${ARCOD:-arcod}"
PORT="${PORT:-8093}"
BASE="http://localhost:${PORT}"
LOG="${LOG:-/tmp/arcod-mini-search.log}"

cleanup() {
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
enc() { jq -rn --arg v "$1" '$v|@uri'; }
post() { curl -fsS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
put() { curl -fsS -X PUT "$BASE$1" -H 'content-type: application/json' -d "$2"; }
del() { curl -fsS -X DELETE "$BASE$1"; }
get() { curl -fsS "$BASE$1"; }
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
[ "$(code /v1/health)" = "200" ] || { echo "service did not start"; tail -20 "$LOG"; exit 1; }

say "index four documents"
A=$(post /v1/docs "$(jq -nc --arg t 'Fencing tokens for distributed locks' --arg b 'A fencing token is a number that only grows. The lock service hands out a token with every lease and the resource remembers the highest number it has seen. A late holder cannot overwrite newer data because its token is older.' --arg g 'distributed,locking' '{title:$t,body:$b,tags:$g}')")
AID=$(echo "$A" | jq -r '.doc.id')
B=$(post /v1/docs "$(jq -nc --arg t 'Inverted index basics' --arg b 'An inverted index maps each term to the documents that contain it. A search engine ranks documents with BM25 and shows a snippet around the matching term.' --arg g 'search,index' '{title:$t,body:$b,tags:$g}')")
BID=$(echo "$B" | jq -r '.doc.id')
C=$(post /v1/docs "$(jq -nc --arg t 'Search ranking with BM25' --arg b 'BM25 scores a document by term frequency and inverse document frequency. Rare terms matter more than common terms; the title gets a boost. Snippets highlight the matching words.' --arg g 'search,ranking' '{title:$t,body:$b,tags:$g}')")
CID=$(echo "$C" | jq -r '.doc.id')
D=$(post /v1/docs "$(jq -nc --arg t 'Arc backend services' --arg b 'Arcod compiles an Arc module into a state machine over HTTP. A service declares records, effects and rules; the generated service keeps the store honest.' --arg g 'arcod,backend' '{title:$t,body:$b,tags:$g}')")
DID=$(echo "$D" | jq -r '.doc.id')
[ "$(echo "$A" | jq -r '.doc.version')" = "1" ]
[ "$(echo "$D" | jq -r '.doc.id')" = "$DID" ]

say "health and stats see four documents"
[ "$(get /v1/health | jq -r .documents)" = "4" ]
STATS=$(get /v1/stats)
[ "$(echo "$STATS" | jq -r .documents)" = "4" ]
[ "$(echo "$STATS" | jq -r .scannedDocs)" = "4" ]
[ "$(echo "$STATS" | jq -r .postings)" -gt 0 ]
[ "$(echo "$STATS" | jq -r .terms)" -gt 0 ]

say "ranking: both terms beat one"
RES=$(get "/v1/search?q=$(enc 'inverted index')")
[ "$(echo "$RES" | jq -r .total)" = "1" ]
[ "$(echo "$RES" | jq -r '.hits[0].title')" = "Inverted index basics" ]
echo "$RES" | jq -r '.hits[0].snippet' | grep -q '<mark>inverted</mark>'
echo "$RES" | jq -r '.hits[0].snippet' | grep -q '<mark>index</mark>'
RES=$(get "/v1/search?q=$(enc 'search engine')")
[ "$(echo "$RES" | jq -r .total)" = "2" ]
[ "$(echo "$RES" | jq -r '.hits[0].title')" = "Inverted index basics" ]
[ "$(echo "$RES" | jq -r '.hits[1].title')" = "Search ranking with BM25" ]

say "phrase, tag and exclusion filters"
[ "$(get "/v1/search?q=$(enc '"inverted index"')" | jq -r .total)" = "1" ]
[ "$(get "/v1/search?q=$(enc '"index inverted"')" | jq -r .total)" = "0" ]
TAGGED=$(get "/v1/search?q=$(enc 'ranking tag:search')")
[ "$(echo "$TAGGED" | jq -r .total)" = "1" ]
[ "$(echo "$TAGGED" | jq -r '.hits[0].title')" = "Search ranking with BM25" ]
[ "$(get "/v1/search?q=$(enc 'ranking tag:backend')" | jq -r .total)" = "0" ]
[ "$(get "/v1/search?q=$(enc 'inverted -maps')" | jq -r .total)" = "0" ]
[ "$(get "/v1/search?q=$(enc '+token')" | jq -r .total)" = "1" ]

say "pagination"
PAGE=$(get "/v1/search?q=$(enc 'search')&limit=1&offset=0")
[ "$(echo "$PAGE" | jq -r .total)" = "2" ]
[ "$(echo "$PAGE" | jq -r '.hits | length')" = "1" ]
PAGE2=$(get "/v1/search?q=$(enc 'search')&limit=1&offset=1")
[ "$(echo "$PAGE2" | jq -r '.hits | length')" = "1" ]
[ "$(echo "$PAGE" | jq -r '.hits[0].docId')" != "$(echo "$PAGE2" | jq -r '.hits[0].docId')" ]

say "invalid queries are 400, before the store"
[ "$(code "/v1/search?q=")" = "400" ]
[ "$(code "/v1/search?q=search&limit=0")" = "400" ]
[ "$(code "/v1/search?q=search&offset=1001")" = "400" ]

say "update reindexes: old terms leave, new terms arrive"
BEFORE=$(get /v1/stats | jq -r .postings)
UPD=$(put "/v1/docs/$BID" "$(jq -nc --arg t 'Inverted index basics' --arg b 'An inverted index maps terms to documents for retrieval. It is the core of every retrieval system.' --arg g 'search,index' '{title:$t,body:$b,tags:$g}')")
[ "$(echo "$UPD" | jq -r '.doc.version')" = "2" ]
[ "$(get "/v1/search?q=$(enc 'BM25')" | jq -r .total)" = "1" ]
[ "$(get "/v1/search?q=$(enc 'snippet')" | jq -r .total)" = "0" ]
[ "$(get "/v1/search?q=$(enc 'retrieval')" | jq -r .total)" = "1" ]
[ "$(get "/v1/search?q=$(enc 'retrieval')" | jq -r '.hits[0].title')" = "Inverted index basics" ]
AFTER=$(get /v1/stats | jq -r .postings)
[ "$AFTER" -lt "$BEFORE" ]
[ "$(get "/v1/docs/$BID" | jq -r .version)" = "2" ]

say "suggestions come from the vocabulary"
SUG=$(get "/v1/suggest?prefix=inv&limit=5")
echo "$SUG" | jq -e 'index("inverted") != null' >/dev/null
[ "$(get "/v1/suggest?prefix=zzz" | jq 'length')" = "0" ]

say "delete removes the document and its postings"
DEL=$(del "/v1/docs/$AID")
[ "$(echo "$DEL" | jq -r .deleted)" = "true" ]
[ "$(echo "$DEL" | jq -r .postings)" -gt 0 ]
[ "$(get "/v1/search?q=$(enc 'fencing')" | jq -r .total)" = "0" ]
[ "$(code "/v1/docs/$AID")" = "404" ]
FINAL=$(get /v1/stats)
[ "$(echo "$FINAL" | jq -r .documents)" = "3" ]
[ "$(echo "$FINAL" | jq -r .scannedDocs)" = "3" ]
[ "$(get /v1/health | jq -r .documents)" = "3" ]

say "PASS"
