#!/usr/bin/env bash
# End-to-end smoke test: build, start the stack, exercise the API, stop it.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8091}"
BASE="http://localhost:$PORT"

cleanup() {
  arcod run --down --impl >/dev/null 2>&1 || true
}
trap cleanup EXIT

arcod build --impl >/dev/null
arcod run --impl --port "$PORT" >/tmp/arcod-sample-001.log 2>&1 &
for _ in $(seq 1 90); do
  if curl -fsS "$BASE/healthz" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS "$BASE/healthz" >/dev/null

say() { printf '%s\n' "$*"; }

say "health: ok"

GROUP=$(curl -fsS -X POST "$BASE/v1/groups" -H 'content-type: application/json' \
  -d '{"name":"Trip","members":["ann","bob","cid"],"currency":"EUR"}')
GID=$(printf '%s' "$GROUP" | jq -r .id)
[ "$(printf '%s' "$GROUP" | jq -r .name)" = "Trip" ]
say "createGroup: $GID"

curl -fsS -X POST "$BASE/v1/groups/$GID/expenses" -H 'content-type: application/json' \
  -d '{"payer":"ann","amount":1000,"participants":["ann","bob","cid"],"note":"dinner"}' >/dev/null
curl -fsS -X POST "$BASE/v1/groups/$GID/expenses" -H 'content-type: application/json' \
  -d '{"payer":"bob","amount":301,"participants":["bob","cid"],"note":"taxi"}' >/dev/null
say "addExpense: 2 expenses"

LEDGER=$(curl -fsS "$BASE/v1/groups/$GID/ledger")
[ "$(printf '%s' "$LEDGER" | jq -r '.expenses | length')" = "2" ]
[ "$(printf '%s' "$LEDGER" | jq -r '.balances[0].member')" = "ann" ]
[ "$(printf '%s' "$LEDGER" | jq -r '.balances[0].net')" = "666" ]
[ "$(printf '%s' "$LEDGER" | jq -r '[.balances[].net] | add')" = "0" ]
say "getLedger: balances sum to zero, ann net +666"

CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/v1/groups/00000000-0000-0000-0000-000000000000/ledger")
[ "$CODE" = "404" ]
say "unknown group: 404"

say "sample 001: PASS"
