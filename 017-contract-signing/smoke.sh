#!/usr/bin/env bash
# End-to-end: mysql + redis queue + s3 + a mail gateway on the compose network.
# Create -> invite -> ordered signing -> reminder -> seal -> manifest verify ->
# tamper detection -> decline path -> stats.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8095}"
MAIL_PORT="${MAIL_PORT:-9097}"
BASE="http://localhost:${PORT}"
MAIL="http://localhost:${MAIL_PORT}"
ARCOD="${ARCOD:-arcod}"
ARCOD_JS="${ARCOD_JS:-}"
RUN_PID=""
MAILER_NAME="arcod-017-mailer"

say() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

arcod_run() {
  if [ -n "$ARCOD_JS" ]; then node "$ARCOD_JS" "$@"; else "$ARCOD" "$@"; fi
}

cleanup() {
  if [ -n "$RUN_PID" ]; then
    kill "$RUN_PID" >/dev/null 2>&1 || true
    wait "$RUN_PID" 2>/dev/null || true
  fi
  docker rm -f "$MAILER_NAME" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

post() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
get() { curl -sS "$BASE$1"; }
status() {
  local body="$2"
  [ -n "$body" ] || body='{}'
  curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$body"
}
get_status() { curl -s -o /dev/null -w '%{http_code}' "$BASE$1"; }

wait_mail() {
  local to="$1" want="$2" got=0
  for _ in $(seq 1 80); do
    got=$(curl -fsS "$MAIL/api/v1/messages?to=$to" | jq '.messages | length')
    [ "$got" -ge "$want" ] && return 0
    sleep 0.5
  done
  fail "no mail for $to (want $want, got $got)"
}

code_from_mail() {
  curl -fsS "$MAIL/api/v1/messages?to=$1" | jq -r '.messages[-1].text' | sed -n 's/^Your code: //p'
}

wait_status() {
  local id="$1" want="$2" got=""
  for _ in $(seq 1 80); do
    got=$(get "/v1/envelopes/$id" | jq -r '.envelope.status')
    [ "$got" = "$want" ] && return 0
    sleep 0.5
  done
  fail "envelope $id stayed $got, want $want"
}

docker rm -f "$MAILER_NAME" >/dev/null 2>&1 || true
docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

arcod_run check >/dev/null
arcod_run build --impl --port "$PORT" >/dev/null
arcod_run run --impl --port "$PORT" >/tmp/arcod-sample-017.log 2>&1 &
RUN_PID=$!

for _ in $(seq 1 180); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || fail "service did not become healthy (see /tmp/arcod-sample-017.log)"
say "health: ok (service + mysql + redis queue + s3)"

# The mail gateway joins the compose network under the name the spec binds.
IMAGE=$(grep -m1 'image: arcod/contract-signing-service' .arcod/build/docker-compose.yml | awk '{print $2}')
SERVICE_ID=$(docker compose -f .arcod/build/docker-compose.yml ps -q service)
NETWORK=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$SERVICE_ID")
[ -n "$IMAGE" ] && [ -n "$NETWORK" ] || fail "cannot find the service image/network"
docker run -d --name "$MAILER_NAME" -p "${MAIL_PORT}:9097" --network "$NETWORK" --network-alias mailer \
  -v "$PWD/mock:/app" -w /app --entrypoint node "$IMAGE" mailbox.mjs >/dev/null
for _ in $(seq 1 60); do
  if curl -fsS "$MAIL/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
curl -fsS "$MAIL/healthz" >/dev/null || fail "mail gateway did not start"
say "mailer: ok"

DOC=$(printf 'MUTUAL NON-DISCLOSURE AGREEMENT\n\n1. The parties keep each other confidential information secret.\n2. The obligations last three years from the signing date.\n3. Either party may terminate with 30 days written notice.\n')

say "create: draft envelope with the document in S3"
CREATED=$(post /v1/envelopes "$(jq -nc --arg d "$DOC" '{title:"NDA Acme",ownerEmail:"owner@acme.test",document:$d}')")
ENV1=$(echo "$CREATED" | jq -r .id)
[ "$(echo "$CREATED" | jq -r .status)" = "draft" ] || fail "new envelope is not draft"
[ "$(echo "$CREATED" | jq -r .documentSize)" -gt 100 ] || fail "document size not stored"
[ "$(get_status "/v1/envelopes/$ENV1" )" = "200" ] || fail "created envelope is not readable"

BAD=$(status /v1/envelopes '{"title":"","ownerEmail":"owner@acme.test","document":"x"}')
[ "$BAD" = "400" ] || fail "empty title answered $BAD, want 400"
BAD=$(status /v1/envelopes '{"title":"X","ownerEmail":"not-an-email","document":"x"}')
[ "$BAD" = "400" ] || fail "bad owner email answered $BAD, want 400"
say "create: 201, invalid title/email 400"

say "signers: turn order is assigned by the server"
S1=$(post "/v1/envelopes/$ENV1/signers" '{"name":"Anna","email":"anna@acme.test"}')
S2=$(post "/v1/envelopes/$ENV1/signers" '{"name":"Bob","email":"bob@acme.test"}')
ANNA=$(echo "$S1" | jq -r .id)
BOB=$(echo "$S2" | jq -r .id)
BOB_API=$(echo "$S2" | jq -r .code)
[ "$(echo "$S1" | jq -r .orderIndex)" = "1" ] || fail "first signer is not turn 1"
[ "$(echo "$S2" | jq -r .orderIndex)" = "2" ] || fail "second signer is not turn 2"
DUP=$(status "/v1/envelopes/$ENV1/signers" '{"name":"Anna again","email":"anna@acme.test"}')
[ "$DUP" = "409" ] || fail "duplicate signer answered $DUP, want 409"
[ "$(get "/v1/envelopes/$ENV1" | jq -r '.signers | length')" = "2" ] || fail "view lost a signer"
say "signers: order 1/2, duplicate 409"

say "send: the first signer is invited by the consumer"
SENT=$(post "/v1/envelopes/$ENV1/send" '{}')
[ "$(echo "$SENT" | jq -r .status)" = "sent" ] || fail "send did not move the envelope to sent"
AGAIN=$(status "/v1/envelopes/$ENV1/send" '{}')
[ "$AGAIN" = "409" ] || fail "second send answered $AGAIN, want 409"
LATE=$(status "/v1/envelopes/$ENV1/signers" '{"name":"Cid","email":"cid@acme.test"}')
[ "$LATE" = "409" ] || fail "signer added after send answered $LATE, want 409"
wait_mail anna@acme.test 1
ANNA_CODE=$(code_from_mail anna@acme.test)
[ -n "$ANNA_CODE" ] || fail "invitation mail carries no code"
say "send: sent, repeat 409, late signer 409, invite code $ANNA_CODE delivered"

say "sign: turn and code are enforced"
OUT=$(status "/v1/envelopes/$ENV1/sign" "{\"email\":\"bob@acme.test\",\"code\":\"$BOB_API\"}")
[ "$OUT" = "409" ] || fail "out-of-turn signature answered $OUT, want 409"
OUT=$(status "/v1/envelopes/$ENV1/sign" '{"email":"anna@acme.test","code":"WRONG"}')
[ "$OUT" = "403" ] || fail "wrong code answered $OUT, want 403"
OUT=$(status "/v1/envelopes/$ENV1/sign" "{\"email\":\"nobody@acme.test\",\"code\":\"$ANNA_CODE\"}")
[ "$OUT" = "403" ] || fail "stranger answered $OUT, want 403"
SIGNED=$(post "/v1/envelopes/$ENV1/sign" "{\"email\":\"anna@acme.test\",\"code\":\"$ANNA_CODE\"}")
[ "$(echo "$SIGNED" | jq -r .envelope.status)" = "in_progress" ] || fail "first signature did not move to in_progress"
[ "$(echo "$SIGNED" | jq -r .envelope.signedCount)" = "1" ] || fail "signedCount is not 1"
OUT=$(status "/v1/envelopes/$ENV1/sign" "{\"email\":\"anna@acme.test\",\"code\":\"$ANNA_CODE\"}")
[ "$OUT" = "409" ] || fail "second signature by the same person answered $OUT, want 409"
wait_mail bob@acme.test 1
BOB_CODE=$(code_from_mail bob@acme.test)
[ "$BOB_CODE" != "$ANNA_CODE" ] || fail "both signers got the same code"
say "sign: out of turn 409, wrong code 403, anna signed, bob invited"

say "remind: the tick mails the current signer, but not twice in a row"
REM=$(post "/v1/envelopes/$ENV1/remind" '{"afterSec":0}')
[ "$(echo "$REM" | jq -r .reminders)" = "1" ] || fail "reminder counter is not 1"
SOON=$(status "/v1/envelopes/$ENV1/remind" '{"afterSec":3600}')
[ "$SOON" = "409" ] || fail "second reminder answered $SOON, want 409"
wait_mail bob@acme.test 2
say "remind: 200 then 409 inside the window, mail delivered"

say "seal: the last signature closes the envelope in a consumer"
DONE=$(post "/v1/envelopes/$ENV1/sign" "{\"email\":\"bob@acme.test\",\"code\":\"$BOB_CODE\"}")
[ "$(echo "$DONE" | jq -r .envelope.status)" != "in_progress" ] || fail "last signature left the envelope in progress"
wait_status "$ENV1" completed
VIEW=$(get "/v1/envelopes/$ENV1")
[ "$(echo "$VIEW" | jq -r .envelope.signedCount)" = "2" ] || fail "signedCount is not 2"
[ "$(echo "$VIEW" | jq -r '[.signers[].status] | unique | join(",")')" = "signed" ] || fail "not every signer is signed"
KINDS=$(echo "$VIEW" | jq -r '[.audit[].kind] | join(",")')
for k in created signer_added sent signed reminded sealed; do
  case ",$KINDS," in *",$k,"*) ;; *) fail "audit lost $k ($KINDS)";; esac
done
say "seal: completed, audit trail $KINDS"

say "manifest: the sealed artefact verifies against the stored document"
MAN=$(get "/v1/envelopes/$ENV1/manifest")
[ "$(echo "$MAN" | jq -r .intact)" = "true" ] || fail "manifest is not intact"
[ "$(echo "$MAN" | jq -r .verified)" = "true" ] || fail "manifest is not verified"
[ "$(echo "$MAN" | jq -r '.signers | length')" = "2" ] || fail "manifest lost a signer"
[ "$(echo "$MAN" | jq -r '[.signers[].verified] | unique | join(",")')" = "true" ] || fail "a signature does not verify"
say "manifest: intact, verified, 2 signatures"

say "tamper: an edited document breaks the signatures, not the seal"
post "/v1/dev/envelopes/$ENV1/tamper" '{"document":"MUTUAL NON-DISCLOSURE AGREEMENT, edited after signing."}' >/dev/null
MAN2=$(get "/v1/envelopes/$ENV1/manifest")
[ "$(echo "$MAN2" | jq -r .intact)" = "true" ] || fail "edited document broke the manifest bytes"
[ "$(echo "$MAN2" | jq -r .verified)" = "false" ] || fail "edited document still verifies"
say "tamper: intact true, verified false"

say "decline: one refusal closes the route"
C2=$(post /v1/envelopes "$(jq -nc --arg d "$DOC" '{title:"NDA Beta",ownerEmail:"owner@acme.test",document:$d}')")
ENV2=$(echo "$C2" | jq -r .id)
post "/v1/envelopes/$ENV2/signers" '{"name":"Cid","email":"cid@acme.test"}' >/dev/null
post "/v1/envelopes/$ENV2/signers" '{"name":"Dana","email":"dana@acme.test"}' >/dev/null
post "/v1/envelopes/$ENV2/send" '{}' >/dev/null
wait_mail cid@acme.test 1
CID_CODE=$(code_from_mail cid@acme.test)
DEC=$(post "/v1/envelopes/$ENV2/decline" "{\"email\":\"cid@acme.test\",\"code\":\"$CID_CODE\",\"reason\":\"terms are not acceptable\"}")
[ "$(echo "$DEC" | jq -r .envelope.status)" = "declined" ] || fail "decline did not close the envelope"
[ "$(echo "$DEC" | jq -r '.signers[0].status')" = "declined" ] || fail "declining signer is not marked"
[ "$(echo "$DEC" | jq -r '.signers[0].reason')" = "terms are not acceptable" ] || fail "reason is not stored"
[ "$(echo "$DEC" | jq -r '.signers[1].status')" = "skipped" ] || fail "the signer behind the refuser was not skipped"
MAN404=$(get_status "/v1/envelopes/$ENV2/manifest")
[ "$MAN404" = "409" ] || fail "manifest of a declined envelope answered $MAN404, want 409"
OUT=$(status "/v1/envelopes/$ENV2/sign" "{\"email\":\"cid@acme.test\",\"code\":\"$CID_CODE\"}")
[ "$OUT" = "409" ] || fail "signature after decline answered $OUT, want 409"
wait_mail owner@acme.test 1
say "decline: declined, reason stored, manifest 409, owner told"

say "stats and errors"
STATS=$(get /v1/stats)
[ "$(echo "$STATS" | jq -r .envelopes)" = "2" ] || fail "stats envelopes is not 2"
[ "$(echo "$STATS" | jq -r .completed)" = "1" ] || fail "stats completed is not 1"
[ "$(echo "$STATS" | jq -r .declined)" = "1" ] || fail "stats declined is not 1"
[ "$(echo "$STATS" | jq -r .notifications)" -ge 5 ] || fail "stats notifications is short"
[ "$(echo "$STATS" | jq -r .pendingSigners)" = "0" ] || fail "stats pendingSigners is not 0"
[ "$(get_status "/v1/envelopes/00000000-0000-0000-0000-000000000000")" = "404" ] || fail "unknown envelope is not 404"
[ "$(get_status "/v1/envelopes/00000000-0000-0000-0000-000000000000/manifest")" = "404" ] || fail "manifest of unknown envelope is not 404"
say "stats: $(echo "$STATS" | jq -c .)"

echo "PASS: contract signing (mysql + redis queue + s3 + mail gateway)"
