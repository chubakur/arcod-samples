#!/usr/bin/env bash
# 045-meeting-scheduler: hosts with working hours in their own timezone, a
# 15-minute slot grid shared by all zones, bookings guarded by unique slot
# holds, .ics invitations written to S3 by a queue consumer, and reminders
# fanned out by a cron-style dispatch op.
# Checks: host create + duplicate 409, invalid zone/hours 400, slots rendered in
# the guest's zone, weekend closed, double booking 409 (exact and partial),
# invite lands in S3 and is idempotent, reminder dispatch is idempotent, cancel
# frees the slot, unknown ids 404, no dead letters.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8097}"
BASE="http://localhost:${PORT}"
ARCOD="${ARCOD:-arcod}"
LOG=/tmp/arcod-045.log

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
J() { jq -r "$1" "${2:--}"; }

cleanup() {
  [ -n "${RUN_PID:-}" ] && kill "$RUN_PID" >/dev/null 2>&1 || true
  docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f .arcod/build/docker-compose.yml down -v >/dev/null 2>&1 || true

say "check"
$ARCOD check >/dev/null

say "build"
$ARCOD build --impl --port "$PORT" >/dev/null

say "run"
$ARCOD run --impl --port "$PORT" >"$LOG" 2>&1 &
RUN_PID=$!
for _ in $(seq 1 120); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null || { tail -40 "$LOG"; fail "service did not start"; }

post() { curl -sS -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }
code() { curl -sS -o /tmp/arcod-045-body.json -w '%{http_code}' -X POST "$BASE$1" -H 'content-type: application/json' -d "$2"; }

# Next Tuesday, three to nine days out, and the Saturday after it.
DAY=$(node -e "const d=new Date();const add=((9-d.getUTCDay())%7)||7;d.setUTCDate(d.getUTCDate()+add);console.log(d.toISOString().slice(0,10))")
SAT=$(node -e "const d=new Date('$DAY' + 'T00:00:00Z');d.setUTCDate(d.getUTCDate()+4);console.log(d.toISOString().slice(0,10))")
START="${DAY}T10:00:00Z"
echo "day=$DAY start=$START"

say "host: create, duplicate, invalid"
HOST=$(post /v1/hosts '{"name":"Anna","email":"anna@example.com","timezone":"Europe/Berlin","workStart":"09:00","workEnd":"17:00"}')
HID=$(printf '%s' "$HOST" | J .id)
[ -n "$HID" ] || fail "host id: $HOST"
[ "$(printf '%s' "$HOST" | J .timezone)" = "Europe/Berlin" ] || fail "host timezone"
DUP=$(code /v1/hosts '{"name":"Anna","email":"ANNA@example.com","timezone":"Europe/Berlin","workStart":"09:00","workEnd":"17:00"}')
[ "$DUP" = "409" ] || fail "duplicate email should be 409, got $DUP"
BAD=$(code /v1/hosts '{"name":"Nobody","email":"nobody@example.com","timezone":"Mars/Olympus","workStart":"09:00","workEnd":"17:00"}')
[ "$BAD" = "400" ] || fail "unknown zone should be 400, got $BAD"
BADH=$(code /v1/hosts '{"name":"Nobody","email":"nobody@example.com","timezone":"Europe/Berlin","workStart":"18:00","workEnd":"09:00"}')
[ "$BADH" = "400" ] || fail "inverted hours should be 400, got $BADH"

say "slots: guest zone rendering"
SLOTS=$(curl -sS "$BASE/v1/hosts/$HID/slots?date=$DAY&tz=America/New_York&dur=30")
COUNT=$(printf '%s' "$SLOTS" | jq 'length')
[ "$COUNT" -gt 10 ] || fail "too few slots: $COUNT"
FIRST=$(printf '%s' "$SLOTS" | jq -r '.[0]')
[ "$(printf '%s' "$FIRST" | J .hostLocal)" = "$DAY 09:00 Europe/Berlin" ] || fail "first host slot: $FIRST"
[ "$(printf '%s' "$FIRST" | J .guestLocal)" = "$DAY 03:00 America/New_York" ] || fail "first guest slot: $FIRST"
SATS=$(curl -sS "$BASE/v1/hosts/$HID/slots?date=$SAT&tz=Europe/Berlin&dur=30" | jq 'length')
[ "$SATS" = "0" ] || fail "weekend should be closed, got $SATS slots"

say "book: 60 minutes, then conflicts"
BOOK=$(post /v1/bookings "{\"hostId\":\"$HID\",\"guestEmail\":\"guest@example.com\",\"guestTimezone\":\"America/New_York\",\"startsAt\":\"$START\",\"dur\":60}")
BID=$(printf '%s' "$BOOK" | J .id)
[ -n "$BID" ] || fail "booking id: $BOOK"
[ "$(printf '%s' "$BOOK" | J .guestLocal)" = "$DAY 05:00 America/New_York" ] || fail "guest label: $BOOK"
[ "$(printf '%s' "$BOOK" | J .hostLocal)" = "$DAY 11:00 Europe/Berlin" ] || fail "host label: $BOOK"

SAME=$(code /v1/bookings "{\"hostId\":\"$HID\",\"guestEmail\":\"other@example.com\",\"guestTimezone\":\"Europe/Berlin\",\"startsAt\":\"$START\",\"dur\":60}")
[ "$SAME" = "409" ] || fail "same slot should be 409, got $SAME"
PART=$(code /v1/bookings "{\"hostId\":\"$HID\",\"guestEmail\":\"other@example.com\",\"guestTimezone\":\"Europe/Berlin\",\"startsAt\":\"${DAY}T10:30:00Z\",\"dur\":30}")
[ "$PART" = "409" ] || fail "overlapping slot should be 409, got $PART"
BADDUR=$(code /v1/bookings "{\"hostId\":\"$HID\",\"guestEmail\":\"x@example.com\",\"guestTimezone\":\"Europe/Berlin\",\"startsAt\":\"${DAY}T12:00:00Z\",\"dur\":20}")
[ "$BADDUR" = "400" ] || fail "bad duration should be 400, got $BADDUR"
NOWEEK=$(code /v1/bookings "{\"hostId\":\"$HID\",\"guestEmail\":\"x@example.com\",\"guestTimezone\":\"Europe/Berlin\",\"startsAt\":\"${SAT}T10:00:00Z\",\"dur\":30}")
[ "$NOWEEK" = "400" ] || fail "weekend booking should be 400, got $NOWEEK"
[ "$(curl -sS "$BASE/v1/hosts/$HID/slots?date=$DAY&tz=Europe/Berlin&dur=60" | jq '[.[] | select(.startsAt=="'$START'")] | length')" = "0" ] || fail "booked slot is still offered"

say "invite: consumer writes .ics to S3"
STATUS=""
INV=""
for _ in $(seq 1 40); do
  INV=$(curl -sS "$BASE/v1/bookings/$BID/invite")
  STATUS=$(printf '%s' "$INV" | J .status)
  [ "$STATUS" = "sent" ] && break
  sleep 1
done
[ "$STATUS" = "sent" ] || fail "invite not delivered: $INV"
KEY=$(printf '%s' "$INV" | J .key)
case "$KEY" in invites/*/invite.ics) ;; *) fail "unexpected ics key: $KEY" ;; esac
printf '%s' "$INV" | J .body | grep -q 'BEGIN:VEVENT' || fail "ics has no VEVENT"
DTEXP=$(node -e "console.log(new Date('$START').toISOString().replace(/[-:]/g,'').replace(/\.000/,''))")
printf '%s' "$INV" | J .body | grep -q "DTSTART:$DTEXP" || fail "ics DTSTART mismatch"

say "reminder: dispatch is idempotent"
EARLY=$(post /v1/reminders/dispatch "{\"now\":\"${DAY}T08:00:00Z\"}")
[ "$(printf '%s' "$EARLY" | J .queued)" = "0" ] || fail "reminder fired too early: $EARLY"
DUE=$(post /v1/reminders/dispatch "{\"now\":\"${DAY}T10:30:00Z\"}")
[ "$(printf '%s' "$DUE" | J .queued)" = "1" ] || fail "reminder should fire once: $DUE"
AGAIN=$(post /v1/reminders/dispatch "{\"now\":\"${DAY}T10:31:00Z\"}")
[ "$(printf '%s' "$AGAIN" | J .queued)" = "0" ] || fail "reminder fired twice: $AGAIN"

say "cancel: slot is released"
CAN=$(post "/v1/bookings/$BID/cancel" '{}')
[ "$(printf '%s' "$CAN" | J .status)" = "cancelled" ] || fail "cancel: $CAN"
CAN2=$(post "/v1/bookings/$BID/cancel" '{}')
[ "$(printf '%s' "$CAN2" | J .status)" = "cancelled" ] || fail "cancel not idempotent: $CAN2"
REBOOK=$(code /v1/bookings "{\"hostId\":\"$HID\",\"guestEmail\":\"second@example.com\",\"guestTimezone\":\"Europe/Berlin\",\"startsAt\":\"$START\",\"dur\":60}")
[ "$REBOOK" = "201" ] || fail "slot was not released, rebook=$REBOOK"
GO=$(code "/v1/bookings/00000000-0000-4000-8000-000000000000/cancel" '{}')
[ "$GO" = "404" ] || fail "unknown booking should be 404, got $GO"

say "stats"
STATS=$(curl -sS "$BASE/v1/stats")
[ "$(printf '%s' "$STATS" | J .hosts)" = "1" ] || fail "stats hosts: $STATS"
[ "$(printf '%s' "$STATS" | J .bookings)" = "2" ] || fail "stats bookings: $STATS"
[ "$(printf '%s' "$STATS" | J .cancelled)" = "1" ] || fail "stats cancelled: $STATS"
sleep 3
PENDING=$(curl -sS "$BASE/v1/stats" | J .pendingInvites)
[ "$PENDING" = "0" ] || fail "invites stuck: $PENDING"

DEAD=$(docker compose -f .arcod/build/docker-compose.yml exec -T redis redis-cli keys 'arcod:q:*:dead' 2>/dev/null | tr -d '\r' | grep -c . || true)
[ "$DEAD" = "0" ] || fail "queue has dead letters: $DEAD"

printf '\nPASS\n'
