#!/usr/bin/env bash
# End-to-end smoke: hand out a lease, refuse a second holder, renew it,
# release it, escalate the fence, expire a lease, win a race, take a set of
# locks with rollback, and prove that a stale holder cannot write.
set -euo pipefail
cd "$(dirname "$0")"

ARCOD="${ARCOD:-arcod}"
PORT="${PORT:-8098}"
BASE="http://localhost:${PORT}"
LOG="${LOG:-/tmp/arcod-fence-locks.log}"

cleanup() {
  "$ARCOD" run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
post() { curl -fsS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
get() { curl -fsS "$BASE$1"; }
status() { curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
field() { jq -r "$1"; }

"$ARCOD" run --down --impl >/dev/null 2>&1 || true

say "build"
"$ARCOD" build --impl >/dev/null

say "start :${PORT}"
"$ARCOD" run --impl --port "$PORT" >"$LOG" 2>&1 &
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null
say "healthy"

# --- one lock, one holder ---------------------------------------------
A=$(post "/v1/locks/orders%2F42/acquire" '{"owner":"worker-a","ttlMs":30000}')
TOK_A=$(echo "$A" | field .token)
FENCE_A=$(echo "$A" | field .lease.fence)
[ -n "$TOK_A" ]
[ "$FENCE_A" = "1" ]
say "worker-a holds orders/42 at fence 1"

[ "$(status "/v1/locks/orders%2F42/acquire" '{"owner":"worker-b"}')" = "409" ]
say "a second holder is refused with 409"

STATE=$(get "/v1/locks/orders%2F42")
[ "$(echo "$STATE" | field .held)" = "true" ]
[ "$(echo "$STATE" | field .fence)" = "1" ]
[ "$(echo "$STATE" | jq 'has("token") or (.lease | has("token"))')" = "false" ]
say "state reports the holder without the token"

# --- renew: only the token works --------------------------------------
BAD_TOKEN=$(jq -nc --arg t "not-the-token" '{token: $t}')
[ "$(status "/v1/locks/orders%2F42/renew" "$BAD_TOKEN")" = "403" ]
GOOD_TOKEN=$(jq -nc --arg t "$TOK_A" '{token: $t, ttlMs: 60000}')
RENEWED=$(post "/v1/locks/orders%2F42/renew" "$GOOD_TOKEN")
[ "$(echo "$RENEWED" | field .renewals)" = "1" ]
[ "$(echo "$RENEWED" | field .ttlMs)" = "60000" ]
say "renewal extends the window and counts itself"

# --- the guarded resource remembers the fence -------------------------
W1_BODY=$(jq -nc --argjson f "$FENCE_A" '{fence: $f, value: "v1", writer: "worker-a"}')
W1=$(post "/v1/resources/ledger/write" "$W1_BODY")
[ "$(echo "$W1" | field .writes)" = "1" ]
REPLAY=$(post "/v1/resources/ledger/write" "$W1_BODY")
[ "$(echo "$REPLAY" | field .writes)" = "1" ]
say "the same fence and the same payload is a replay, not a second write"

# --- release and re-grant: the fence may only grow --------------------
REL=$(post "/v1/locks/orders%2F42/release" "$GOOD_TOKEN")
[ "$(echo "$REL" | field .fence)" = "1" ]
[ "$(get "/v1/locks/orders%2F42" | field .held)" = "false" ]

B=$(post "/v1/locks/orders%2F42/acquire" '{"owner":"worker-b","ttlMs":30000}')
TOK_B=$(echo "$B" | field .token)
FENCE_B=$(echo "$B" | field .lease.fence)
[ "$FENCE_B" = "2" ]
say "the next holder gets fence 2, never 1 again"

STALE_RELEASE=$(jq -nc --arg t "$TOK_A" '{token: $t}')
[ "$(status "/v1/locks/orders%2F42/release" "$STALE_RELEASE")" = "403" ]
STALE_WRITE=$(jq -nc --argjson f "$FENCE_A" '{fence: $f, value: "stale", writer: "worker-a"}')
[ "$(status "/v1/resources/ledger/write" "$STALE_WRITE")" = "409" ]
say "the previous holder can neither release nor write"

FRESH_WRITE=$(jq -nc --argjson f "$FENCE_B" '{fence: $f, value: "v2", writer: "worker-b"}')
W2=$(post "/v1/resources/ledger/write" "$FRESH_WRITE")
[ "$(echo "$W2" | field .writes)" = "2" ]
[ "$(echo "$W2" | field .value)" = "v2" ]

LIST=$(get "/v1/locks")
[ "$(echo "$LIST" | jq '[.[] | select(.name == "orders/42")] | length')" = "1" ]
[ "$(echo "$LIST" | jq -r '.[0].fence')" = "2" ]
say "the listing shows one live lease at fence 2"

HIST=$(get "/v1/locks/orders%2F42/history")
[ "$(echo "$HIST" | jq '[.[] | select(.kind == "acquired")] | length')" = "2" ]
[ "$(echo "$HIST" | jq '[.[] | select(.kind == "released")] | length')" = "1" ]
[ "$(echo "$HIST" | jq -r '[.[] | select(.kind == "acquired") | .fence] | max')" = "2" ]
say "history keeps both grants and the release"

# --- a lease that nobody renews expires and is taken over -------------
S=$(post "/v1/locks/short%2Flived/acquire" '{"owner":"slow","ttlMs":1000}')
TOK_S=$(echo "$S" | field .token)
FENCE_S=$(echo "$S" | field .lease.fence)
[ "$FENCE_S" = "1" ]
SLOW_WRITE=$(jq -nc --argjson f "$FENCE_S" '{fence: $f, value: "slow", writer: "slow"}')
post "/v1/resources/report/write" "$SLOW_WRITE" >/dev/null
sleep 1.3

EXPIRED=$(get "/v1/locks/short%2Flived")
[ "$(echo "$EXPIRED" | field .held)" = "false" ]
say "an expired lease stops being held without any sweeper"

F=$(post "/v1/locks/short%2Flived/acquire" '{"owner":"fast","ttlMs":30000}')
TOK_F=$(echo "$F" | field .token)
FENCE_F=$(echo "$F" | field .lease.fence)
[ "$FENCE_F" = "2" ]

SAME_OLD=$(jq -nc --arg t "$TOK_S" '{token: $t}')
[ "$(status "/v1/locks/short%2Flived/renew" "$SAME_OLD")" = "403" ]
LATE=$(jq -nc --argjson f "$FENCE_S" '{fence: $f, value: "late", writer: "slow"}')
[ "$(status "/v1/resources/report/write" "$LATE")" = "409" ]
FAST=$(jq -nc --argjson f "$FENCE_F" '{fence: $f, value: "fast", writer: "fast"}')
SAVED=$(post "/v1/resources/report/write" "$FAST")
[ "$(echo "$SAVED" | field .value)" = "fast" ]
[ "$(echo "$SAVED" | field .writes)" = "2" ]
[ "$(get "/v1/locks/short%2Flived/history" | jq '[.[] | select(.kind == "expired")] | length')" = "1" ]
say "the paused holder is fenced off: its late write is refused"

# --- six clients, one winner ------------------------------------------
rm -f /tmp/arcod-fence-race-*
RACE_PIDS=()
for i in 1 2 3 4 5 6; do
  RACE=$(jq -nc --arg owner "w$i" '{owner: $owner, ttlMs: 10000}')
  status "/v1/locks/race%2Fone/acquire" "$RACE" >"/tmp/arcod-fence-race-$i" &
  RACE_PIDS+=($!)
done
wait "${RACE_PIDS[@]}"
WINS=$(cat /tmp/arcod-fence-race-* | grep -c '^201$' || true)
[ "$WINS" = "1" ]
[ "$(get "/v1/locks/race%2Fone/history" | jq '[.[] | select(.kind == "acquired")] | length')" = "1" ]
say "six simultaneous acquires, exactly one grant"

# --- a set of locks: canonical order and rollback ---------------------
SET=$(post "/v1/locks/acquire" '{"names":["orders/2","orders/1"],"owner":"batch","ttlMs":30000}')
[ "$(echo "$SET" | jq 'length')" = "2" ]
[ "$(echo "$SET" | jq -r '[.[].lease.name] | sort | join(",")')" = "orders/1,orders/2" ]
[ "$(status "/v1/locks/orders%2F1/acquire" '{"owner":"other"}')" = "409" ]
say "a set is taken in one canonical order"

[ "$(status "/v1/locks/acquire" '{"names":["orders/1","orders/3"],"owner":"greedy"}')" = "409" ]
[ "$(get "/v1/locks/orders%2F3" | field .held)" = "false" ]
say "a partial set is rolled back: orders/3 is not left dangling"

T1=$(echo "$SET" | jq -r '.[] | select(.lease.name == "orders/1") | .token')
T2=$(echo "$SET" | jq -r '.[] | select(.lease.name == "orders/2") | .token')
post "/v1/locks/orders%2F1/release" "$(jq -nc --arg t "$T1" '{token: $t}')" >/dev/null
post "/v1/locks/orders%2F2/release" "$(jq -nc --arg t "$T2" '{token: $t}')" >/dev/null
AGAIN=$(post "/v1/locks/acquire" '{"names":["orders/1","orders/2"],"owner":"batch","ttlMs":30000}')
[ "$(echo "$AGAIN" | jq -r '[.[].lease.fence] | min')" = "2" ]
say "re-taking the set escalates both fences"

# --- validation -------------------------------------------------------
[ "$(status "/v1/locks/x%2Fy/acquire" '{"owner":"w","ttlMs":10}')" = "400" ]
[ "$(status "/v1/locks/x%2Fy/acquire" '{"owner":""}')" = "400" ]
[ "$(status "/v1/locks/acquire" '{"names":[],"owner":"w"}')" = "400" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/locks?limit=0")" = "400" ]
say "bad input is rejected before it reaches the store"

post "/v1/locks/orders%2F42/release" "$(jq -nc --arg t "$TOK_B" '{token: $t}')" >/dev/null
post "/v1/locks/short%2Flived/release" "$(jq -nc --arg t "$TOK_F" '{token: $t}')" >/dev/null

say "PASS"
