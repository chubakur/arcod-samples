#!/usr/bin/env bash
# 049-content-moderation: policy-driven moderation with Keycloak reviewers,
# Postgres records, Redis consumers (screen, notify, rescreen) and S3 evidence.
# Four external systems: keycloak, postgres, redis, minio.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8096}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-049.log
BODY=/tmp/arcod-049-body.json

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:-$BODY}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Keycloak has no published port: tokens are minted from inside the compose
# network, by the service container, as a real client would.
token() {
  docker compose -f .arcod/build/docker-compose.yml exec -T service node -e "
fetch('http://idp:8080/realms/arcod/protocol/openid-connect/token', {
  method: 'POST',
  headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: 'grant_type=password&client_id=arcod-web&username=' + process.argv[1] + '&password=' + process.argv[1]
}).then((r) => r.json()).then((j) => {
  if (!j.access_token) { console.error(JSON.stringify(j)); process.exit(1); }
  process.stdout.write(j.access_token);
});
" "$1" 2>/dev/null | tr -d '\n'
}

getc() { curl -sS -o "$BODY" -w '%{http_code}' "$BASE$1" -H "authorization: Bearer ${2:-none}"; }
getj() { getc "$1" "${2:-}" >/dev/null; cat "$BODY"; }
postc() { curl -sS -o "$BODY" -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -H "authorization: Bearer ${2:-none}" -d "$3"; }
post() { postc "$1" "$2" "$3" >/dev/null; cat "$BODY"; }

wait_item() {
  local id="$1" tok="$2" want="$3"
  for _ in $(seq 1 80); do
    local s
    s=$(getj "/v1/items/$id" "$tok" | jq -r .item.status)
    [ "$s" = "$want" ] && return 0
    sleep 0.25
  done
  return 1
}

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

say "check"
$ARCOD check >/dev/null

say "build"
$ARCOD build --impl --port "$PORT" >/dev/null

say "run"
$ARCOD run --impl --port "$PORT" >"$LOG" 2>&1 &
RUN_PID=$!
for _ in $(seq 1 180); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -80 "$LOG"; fail "service did not start"; }

say "identity: anonymous is 401, tokens for four users"
[ "$(getc /v1/items)" = "401" ] || fail "anonymous list must be 401"
ALICE=$(token alice); BOB=$(token bob); CAROL=$(token carol); DAVE=$(token dave)
[ -n "$ALICE" ] && [ -n "$BOB" ] && [ -n "$CAROL" ] && [ -n "$DAVE" ] || fail "token minting failed"

say "reviewers: first is admin, self-registration is reviewer, admin promotes"
[ "$(postc /v1/reviewers "$ALICE" '{"name":"Alice Admin"}')" = "201" ] || fail "alice register must be 201"
[ "$(J .role)" = "admin" ] || fail "first reviewer must be admin"
[ "$(postc /v1/reviewers "$BOB" '{"name":"Bob Senior"}')" = "201" ] || fail "bob register must be 201"
BOB_RID=$(J .id)
[ "$(J .role)" = "reviewer" ] || fail "bob must start as reviewer"
[ "$(postc /v1/reviewers "$CAROL" '{"name":"Carol Reviewer","role":"senior"}')" = "403" ] || fail "self-promotion must be 403"
PROMO=$(printf '{"reviewerId":"%s","role":"senior"}' "$BOB_RID")
[ "$(postc "/v1/reviewers/$BOB_RID/role" "$ALICE" "$PROMO")" = "201" ] || fail "admin promotion must be 201"
[ "$(J .role)" = "senior" ] || fail "bob must be senior"
[ "$(postc /v1/reviewers "$CAROL" '{"name":"Carol Reviewer"}')" = "201" ] || fail "carol register must be 201"
[ "$(J .role)" = "reviewer" ] || fail "carol must be reviewer"

say "policy: admin only, versioned, old versions deactivated"
[ "$(postc /v1/policies "$DAVE" '{"name":"v1","terms":"scam,free-money,guaranteed"}')" = "403" ] || fail "non-admin policy must be 403"
P1=$(printf '{"name":"baseline","terms":"scam,free-money,guaranteed","linkWeight":10,"threshold":50}')
[ "$(postc /v1/policies "$ALICE" "$P1")" = "201" ] || fail "policy v1 must be 201"
[ "$(J .version)" = "1" ] || fail "first policy must be version 1"
[ "$(J .active)" = "true" ] || fail "first policy must be active"

say "screen: clean text auto-approves and writes evidence to S3"
[ "$(postc /v1/items "$DAVE" '{"kind":"post","text":"A calm note about tomatoes and rain."}')" = "201" ] || fail "clean submit must be 201"
CLEAN=$(J .id)
[ "$(J .status)" = "screening" ] || fail "submit must return screening"
wait_item "$CLEAN" "$DAVE" approved || fail "clean item was not auto-approved"
CLEAN_JSON=$(getj "/v1/items/$CLEAN" "$DAVE")
[ "$(printf '%s' "$CLEAN_JSON" | jq -r .item.decidedBy)" = "policy:v1" ] || fail "auto decision must name policy:v1"
EV=$(getj "/v1/items/$CLEAN/evidence" "$CAROL")
[ "$(printf '%s' "$EV" | jq -r .content | grep -c 'baseline\|policyVersion')" -ge 1 ] || fail "evidence snapshot missing"
[ "$(getc "/v1/items/$CLEAN/evidence" "$DAVE")" = "403" ] || fail "author evidence must be 403"

say "screen: banned terms and a link cross the threshold, item waits for a human"
[ "$(postc /v1/items "$DAVE" '{"kind":"post","text":"Buy scam free-money now https://deal.example"}')" = "201" ] || fail "risky submit must be 201"
RISKY=$(J .id)
wait_item "$RISKY" "$DAVE" pending || fail "risky item was not queued"
RISKY_JSON=$(getj "/v1/items/$RISKY" "$DAVE")
[ "$(printf '%s' "$RISKY_JSON" | jq -r .item.risk)" = "70" ] || fail "risk must be 70"
[ "$(printf '%s' "$RISKY_JSON" | jq -r .item.flags | grep -c 'scam')" = "1" ] || fail "flags must name the term"

say "queue: staff only, contains the risky item"
[ "$(getc /v1/queue "$DAVE")" = "403" ] || fail "author queue must be 403"
[ "$(getj /v1/queue "$CAROL" | jq '[.[] | select(.id == "'"$RISKY"'")] | length')" = "1" ] || fail "risky item missing from queue"

say "decision: reviewer rejects, author cannot decide, second decision is 409"
[ "$(postc "/v1/items/$RISKY/decision" "$DAVE" '{"decision":"reject","reason":"nope"}')" = "403" ] || fail "author decision must be 403"
DEC=$(printf '{"decision":"reject","reason":"banned terms and a solicitation link"}')
[ "$(postc "/v1/items/$RISKY/decision" "$CAROL" "$DEC")" = "201" ] || fail "reject must be 201"
[ "$(J .status)" = "rejected" ] || fail "item must be rejected"
[ "$(postc "/v1/items/$RISKY/decision" "$BOB" "$DEC")" = "409" ] || fail "second decision must be 409"

say "appeal: author only, one per item, senior resolves and overturns"
[ "$(postc "/v1/items/$RISKY/appeal" "$BOB" '{"reason":"not mine"}')" = "403" ] || fail "foreign appeal must be 403"
[ "$(postc "/v1/items/$RISKY/appeal" "$DAVE" '{"reason":"the link was a quote"}')" = "201" ] || fail "appeal must be 201"
APPEAL=$(J .id)
[ "$(J .status)" = "open" ] || fail "appeal must start open"
[ "$(postc "/v1/items/$RISKY/appeal" "$DAVE" '{"reason":"again"}')" = "409" ] || fail "second appeal must be 409"
[ "$(postc "/v1/appeals/$APPEAL/resolve" "$CAROL" '{"outcome":"overturn"}')" = "403" ] || fail "reviewer resolve must be 403"
[ "$(postc "/v1/appeals/$APPEAL/resolve" "$BOB" '{"outcome":"overturn","note":"quote context accepted"}')" = "201" ] || fail "senior resolve must be 201"
[ "$(J .status)" = "overturned" ] || fail "appeal must be overturned"
RISKY_JSON=$(getj "/v1/items/$RISKY" "$DAVE")
[ "$(printf '%s' "$RISKY_JSON" | jq -r .item.status)" = "approved" ] || fail "overturn must approve the item"
[ "$(printf '%s' "$RISKY_JSON" | jq '.decisions | length')" = "1" ] || fail "item must carry one decision"
[ "$(printf '%s' "$RISKY_JSON" | jq '.appeals | length')" = "1" ] || fail "item must carry one appeal"

say "rescreen: a new policy pulls back an item the old policy auto-approved"
[ "$(postc /v1/items "$DAVE" '{"kind":"comment","text":"limited offer inside, no links"}')" = "201" ] || fail "offer submit must be 201"
OFFER=$(J .id)
wait_item "$OFFER" "$DAVE" approved || fail "offer item was not auto-approved under v1"
P2=$(printf '{"name":"strict","terms":"offer,scam","linkWeight":10,"threshold":10}')
[ "$(postc /v1/policies "$ALICE" "$P2")" = "201" ] || fail "policy v2 must be 201"
[ "$(J .version)" = "2" ] || fail "second policy must be version 2"
wait_item "$OFFER" "$DAVE" pending || fail "rescreen did not pull the offer item back"
OFFER_JSON=$(getj "/v1/items/$OFFER" "$DAVE")
[ "$(printf '%s' "$OFFER_JSON" | jq -r .item.flags | grep -c 'offer')" = "1" ] || fail "rescreened flags must name offer"
[ "$(getj "/v1/policies" "$DAVE" | jq '[.[] | select(.active == true)] | length')" = "1" ] || fail "exactly one active policy expected"
[ "$(getj "/v1/policies" "$DAVE" | jq '.[0].version')" = "2" ] || fail "newest policy must be listed first"

say "stats: total/pending/approved/auto/escalated counters"
STATS=$(getj /v1/stats "$ALICE")
[ "$(printf '%s' "$STATS" | jq -r .total)" = "3" ] || fail "three items expected"
[ "$(printf '%s' "$STATS" | jq -r .pending)" = "1" ] || fail "one pending item expected"
[ "$(printf '%s' "$STATS" | jq -r .approved)" = "2" ] || fail "two approved items expected"
[ "$(printf '%s' "$STATS" | jq -r .autoApproved)" = "1" ] || fail "one auto-approved item expected"
[ "$(printf '%s' "$STATS" | jq -r .openAppeals)" = "0" ] || fail "no open appeals expected"
[ "$(getc /v1/stats "$DAVE")" = "403" ] || fail "author stats must be 403"

say "sweep: overdue item escalates once, second sweep is idempotent"
SWEEP='{"now":"2099-01-01T00:00:00Z"}'
[ "$(post /v1/sweep "" "$SWEEP" | jq -r .escalated)" = "1" ] || fail "first sweep must escalate one item"
[ "$(post /v1/sweep "" "$SWEEP" | jq -r .escalated)" = "0" ] || fail "second sweep must be idempotent"
[ "$(getj /v1/stats "$ALICE" | jq -r .escalated)" = "1" ] || fail "escalated counter must be 1"

say "notifications: unread inbox, owner-only read"
UNREAD=$(getj '/v1/notifications?unread=true' "$DAVE")
[ "$(printf '%s' "$UNREAD" | jq 'length')" -ge 1 ] || fail "author must have unread notifications"
NID=$(printf '%s' "$UNREAD" | jq -r '.[0].id')
[ "$(postc "/v1/notifications/$NID/read" "$CAROL" '{}')" = "403" ] || fail "foreign notification read must be 403"
[ "$(postc "/v1/notifications/$NID/read" "$DAVE" '{}')" = "201" ] || fail "own notification read must answer"
[ "$(J .readAt)" != null ] || fail "readAt missing"

say "audit and dead letters"
[ "$(getj '/v1/audit?limit=100' "$ALICE" | jq '[.[] | select(.action == "item.rescreened")] | length')" -ge 1 ] || fail "rescreen audit row missing"
[ "$(getj /v1/dead | jq 'length')" = "0" ] || fail "dead letters must be empty"

printf '\nPASS 049-content-moderation: 4 external systems (keycloak, postgres, redis, minio), 3 consumers, %s\n' "$BASE"
