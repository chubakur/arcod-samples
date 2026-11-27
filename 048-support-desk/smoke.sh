#!/usr/bin/env bash
# 048-support-desk: multi-tenant help desk with Keycloak sign-in, Postgres
# metadata, MinIO attachments/exports and Redis queue consumers (triage,
# notify, exportRun). Four providers: keycloak, postgres, redis, minio.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8094}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-048.log
BODY=/tmp/arcod-048-body.json

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:-$BODY}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Keycloak has no published port: tokens are minted from inside the compose
# network, by the service container, exactly as a real client would.
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
postc() { curl -sS -o "$BODY" -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -H "authorization: Bearer ${2:-none}" -d "$3"; }
post() { postc "$1" "$2" "$3" >/dev/null; cat "$BODY"; }
getj() { getc "$1" "${2:-}" >/dev/null; cat "$BODY"; }

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

say "identity: anonymous is 401, each user gets a token"
[ "$(getc /v1/tenants)" = "401" ] || fail "anonymous must be 401"
ALICE=$(token alice); BOB=$(token bob); CAROL=$(token carol); DAVE=$(token dave)
[ -n "$ALICE" ] && [ -n "$BOB" ] && [ -n "$CAROL" ] && [ -n "$DAVE" ] || fail "token minting failed"

say "tenants: create, duplicate slug 409, invalid slug 400"
TENANT=$(printf '{"name":"Acme","slug":"acme","inviteCode":"acmejoin"}')
[ "$(postc /v1/tenants "$ALICE" "$TENANT")" = "201" ] || fail "tenant create must be 201"
TID=$(J .tenant.id)
[ -n "$TID" ] && [ "$TID" != null ] || fail "tenant id missing"
DUP=$(printf '{"name":"Acme 2","slug":"acme","inviteCode":"acmejoin"}')
[ "$(postc /v1/tenants "$ALICE" "$DUP")" = "409" ] || fail "duplicate slug must be 409"
BAD=$(printf '{"name":"Bad","slug":"A","inviteCode":"short"}')
[ "$(postc /v1/tenants "$ALICE" "$BAD")" = "400" ] || fail "bad slug must be 400"
[ "$(getj /v1/tenants "$ALICE" | jq -r '.[0].role')" = "owner" ] || fail "creator must be owner"

say "membership: wrong code 403, correct join 201, idempotent repeat"
WRONG=$(printf '{"tenantId":"%s","inviteCode":"nope"}' "$TID")
[ "$(postc "/v1/tenants/$TID/join" "$CAROL" "$WRONG")" = "403" ] || fail "wrong invite code must be 403"
JOIN=$(printf '{"tenantId":"%s","inviteCode":"acmejoin"}' "$TID")
[ "$(postc "/v1/tenants/$TID/join" "$CAROL" "$JOIN")" = "201" ] || fail "carol join must be 201"
CAROL_ID=$(J .userId)
[ "$(postc "/v1/tenants/$TID/join" "$CAROL" "$JOIN")" = "201" ] || fail "repeat join must answer"
[ "$(J .userId)" = "$CAROL_ID" ] || fail "repeat join must return the same membership"

say "ticket: requester creates, high priority from text, triage assigns the owner"
NEWT=$(printf '{"tenantId":"%s","subject":"Payment down","body":"checkout returns 500"}' "$TID")
[ "$(postc "/v1/tenants/$TID/tickets" "$CAROL" "$NEWT")" = "201" ] || fail "ticket create must be 201"
TICKET=$(J .id)
[ "$(J .priority)" = "high" ] || fail "text with 'down' must be high priority"
[ "$(J .status)" = "open" ] || fail "new ticket must be open"
ASSIGNEE=""
for _ in $(seq 1 40); do
  VIEW=$(getj "/v1/tickets/$TICKET" "$CAROL")
  ASSIGNEE=$(printf '%s' "$VIEW" | jq -r .ticket.assignee)
  [ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != null ] && break
  sleep 0.25
done
[ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != null ] || fail "triage consumer did not assign the ticket"
[ "$ASSIGNEE" != "$CAROL_ID" ] || fail "requester must not be the assignee"
[ "$(printf '%s' "$VIEW" | jq -r '.messages | length')" = "1" ] || fail "ticket must start with one message"

say "notifications: the triage->notify chain wakes the assignee"
for _ in $(seq 1 40); do
  N=$(getj /v1/notifications "$ALICE")
  [ "$(printf '%s' "$N" | jq 'length')" -ge 1 ] && break
  sleep 0.25
done
[ "$(printf '%s' "$N" | jq 'length')" -ge 1 ] || fail "assignee got no notification"

say "staff: bob joins, owner promotes him, assignment moves the ticket"
[ "$(postc "/v1/tenants/$TID/join" "$BOB" "$JOIN")" = "201" ] || fail "bob join must be 201"
BOB_ID=$(J .userId)
PROMO=$(printf '{"tenantId":"%s","userId":"%s","role":"agent"}' "$TID" "$BOB_ID")
[ "$(postc "/v1/tenants/$TID/promote" "$CAROL" "$PROMO")" = "403" ] || fail "non-owner promote must be 403"
[ "$(postc "/v1/tenants/$TID/promote" "$ALICE" "$PROMO")" = "201" ] || fail "owner promote must be 201"
[ "$(J .role)" = "agent" ] || fail "bob must be agent"
ASSIGN=$(printf '{"ticketId":"%s","assignee":"%s"}' "$TICKET" "$BOB_ID")
[ "$(postc "/v1/tickets/$TICKET/assign" "$ALICE" "$ASSIGN")" = "201" ] || fail "assign must be 201"
[ "$(J .assignee)" = "$BOB_ID" ] || fail "assignee must be bob"
[ "$(postc "/v1/tickets/$TICKET/assign" "$CAROL" "$ASSIGN")" = "403" ] || fail "requester assign must be 403"

say "thread: internal note hidden from requester, public reply notifies"
NOTE=$(printf '{"ticketId":"%s","body":"internal triage note","internal":true}' "$TICKET")
[ "$(postc "/v1/tickets/$TICKET/messages" "$ALICE" "$NOTE")" = "201" ] || fail "internal note must be 201"
[ "$(postc "/v1/tickets/$TICKET/messages" "$CAROL" "$NOTE")" = "403" ] || fail "requester internal note must be 403"
VIEW=$(getj "/v1/tickets/$TICKET" "$CAROL")
[ "$(printf '%s' "$VIEW" | jq -r '.messages | length')" = "1" ] || fail "requester must not see internal note"
PUB=$(printf '{"ticketId":"%s","body":"we are on it"}' "$TICKET")
[ "$(postc "/v1/tickets/$TICKET/messages" "$BOB" "$PUB")" = "201" ] || fail "public reply must be 201"
for _ in $(seq 1 40); do
  N=$(getj /v1/notifications "$CAROL")
  [ "$(printf '%s' "$N" | jq 'length')" -ge 1 ] && break
  sleep 0.25
done
[ "$(printf '%s' "$N" | jq 'length')" -ge 1 ] || fail "requester was not notified"
NID=$(printf '%s' "$N" | jq -r '.[0].id')
[ "$(postc "/v1/notifications/$NID/read" "$DAVE" '{}')" = "403" ] || fail "foreign notification read must be 403"
[ "$(postc "/v1/notifications/$NID/read" "$CAROL" '{}')" = "201" ] || fail "own notification read must answer"
[ "$(J .readAt)" != null ] || fail "notification readAt missing"
[ "$(getj '/v1/notifications?unread=true' "$CAROL" | jq 'length')" = "0" ] || fail "no unread after read"

say "attachments: text object in MinIO, metadata in Postgres"
ATT=$(printf '{"ticketId":"%s","name":"error.log","content":"stack trace 500"}' "$TICKET")
[ "$(postc "/v1/tickets/$TICKET/attachments" "$CAROL" "$ATT")" = "201" ] || fail "attach must be 201"
AID=$(J .id)
[ "$(J .size)" = "15" ] || fail "attachment size must be 15"
[ "$(getj "/v1/tickets/$TICKET/attachments/$AID" "$ALICE" | jq -r .content)" = "stack trace 500" ] || fail "attachment bytes mismatch"

say "export: staff only, consumer writes JSONL, download returns it"
EX=$(printf '{"tenantId":"%s"}' "$TID")
[ "$(postc "/v1/tenants/$TID/export" "$CAROL" "$EX")" = "403" ] || fail "requester export must be 403"
[ "$(postc "/v1/tenants/$TID/export" "$ALICE" "$EX")" = "201" ] || fail "owner export must be 201"
EID=$(J .id)
[ "$(J .status)" = "queued" ] || fail "export must start queued"
[ "$(getc "/v1/tenants/$TID/exports/$EID" "$ALICE")" = "409" ] || fail "download of queued export must be 409"
STATUS=""
for _ in $(seq 1 60); do
  EXPORTS=$(getj "/v1/tenants/$TID/exports" "$ALICE")
  STATUS=$(printf '%s' "$EXPORTS" | jq -r '.[0].status')
  [ "$STATUS" = "ready" ] && break
  sleep 0.25
done
[ "$STATUS" = "ready" ] || fail "export consumer did not finish"
[ "$(getj "/v1/tenants/$TID/exports/$EID" "$ALICE" | jq -r .content | grep -c 'Payment down')" = "1" ] || fail "export must contain the ticket subject"

say "stats and audit"
STATS=$(getj "/v1/tenants/$TID/stats" "$ALICE")
[ "$(printf '%s' "$STATS" | jq -r .open)" = "1" ] || fail "one open ticket expected"
[ "$(printf '%s' "$STATS" | jq -r .members)" = "3" ] || fail "three members expected"
[ "$(getj "/v1/tenants/$TID/audit" "$ALICE" | jq '[.[] | select(.action == "ticket.triaged")] | length')" = "1" ] || fail "triage audit row missing"

say "sweep: one breach, idempotent second sweep, notification"
SWEEP='{"now":"2099-01-01T00:00:00Z"}'
[ "$(post /v1/sweep "" "$SWEEP" | jq -r .breached)" = "1" ] || fail "first sweep must breach one ticket"
[ "$(post /v1/sweep "" "$SWEEP" | jq -r .breached)" = "0" ] || fail "second sweep must be idempotent"
[ "$(getj "/v1/tenants/$TID/stats" "$ALICE" | jq -r .breached)" = "1" ] || fail "breached counter must be 1"

say "resolve, double resolve 409, customer reply reopens"
RESOLVE=$(printf '{"ticketId":"%s"}' "$TICKET")
[ "$(postc "/v1/tickets/$TICKET/resolve" "$BOB" "$RESOLVE")" = "201" ] || fail "resolve must be 201"
[ "$(J .status)" = "resolved" ] || fail "ticket must be resolved"
[ "$(postc "/v1/tickets/$TICKET/resolve" "$BOB" "$RESOLVE")" = "409" ] || fail "double resolve must be 409"
FOLLOW=$(printf '{"ticketId":"%s","body":"still broken"}' "$TICKET")
[ "$(postc "/v1/tickets/$TICKET/messages" "$CAROL" "$FOLLOW")" = "201" ] || fail "customer follow-up must be 201"
[ "$(getj "/v1/tickets/$TICKET" "$CAROL" | jq -r .ticket.status)" = "open" ] || fail "customer reply must reopen"

say "isolation: another tenant sees nothing"
[ "$(getc "/v1/tickets/$TICKET" "$DAVE")" = "403" ] || fail "foreign ticket must be 403"
[ "$(getc "/v1/tenants/$TID/stats" "$DAVE")" = "403" ] || fail "foreign stats must be 403"
OTHER=$(printf '{"name":"Other","slug":"other","inviteCode":"otherjoin"}')
[ "$(postc /v1/tenants "$DAVE" "$OTHER")" = "201" ] || fail "second tenant must be created"
OTID=$(J .tenant.id)
[ "$(getc "/v1/tenants/$OTID/stats" "$CAROL")" = "403" ] || fail "cross-tenant stats must be 403"
[ "$(getc "/v1/tenants/$OTID/stats" "$DAVE")" = "200" ] || fail "own tenant stats must be 200"
[ "$(getj "/v1/tenants/$OTID/tickets" "$DAVE" | jq 'length')" = "0" ] || fail "other tenant must have no tickets"

say "dead letters"
[ "$(getj /v1/dead | jq 'length')" = "0" ] || fail "dead letters must be empty"

printf '\nPASS 048-support-desk: 4 providers (keycloak, postgres, redis, minio), 3 consumers, %s\n' "$BASE"
