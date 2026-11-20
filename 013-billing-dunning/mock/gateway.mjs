// External payment gateway, mocked over HTTP. Behavior is driven by the card
// token so the smoke test can hit the happy path, one soft decline and a hard
// decline without any real money.
import http from 'node:http';
import { appendFileSync } from 'node:fs';

const PORT = Number(process.env.PORT || 9099);
const LOG = process.env.GATEWAY_LOG || '/tmp/arcod-013-gateway.jsonl';
const attempts = new Map();   // invoiceId -> accepted attempts
const idempotent = new Map(); // idempotencyKey -> reply

function decide(body) {
  const token = String(body.cardToken || '');
  const invoiceId = String(body.invoiceId || '');
  if (token === 'tok_dead') {
    return { status: 'declined', code: 'insufficient_funds' };
  }
  if (token === 'tok_flaky') {
    const seen = attempts.get(invoiceId) || 0;
    if (seen === 0) {
      attempts.set(invoiceId, 1);
      return { status: 'declined', code: 'try_again' };
    }
    attempts.set(invoiceId, seen + 1);
    return { status: 'approved', ref: 'gw_' + invoiceId.slice(0, 8) + '_' + (seen + 1) };
  }
  const seen = attempts.get(invoiceId) || 0;
  attempts.set(invoiceId, seen + 1);
  return { status: 'approved', ref: 'gw_' + invoiceId.slice(0, 8) + '_' + (seen + 1) };
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
    return;
  }
  if (req.method !== 'POST' || req.url !== '/v1/charge') {
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"error":"not_found"}');
    return;
  }
  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', () => {
    let body = {};
    try { body = JSON.parse(raw || '{}'); } catch { body = {}; }
    const key = String(body.idempotencyKey || '');
    let reply = key ? idempotent.get(key) : null;
    if (!reply) {
      reply = decide(body);
      if (key) idempotent.set(key, reply);
    }
    // One line per gateway decision; the smoke test counts these.
    appendFileSync(LOG, JSON.stringify({
      at: new Date().toISOString(),
      invoiceId: body.invoiceId,
      amountCents: body.amountCents,
      cardToken: body.cardToken,
      idempotencyKey: key,
      reply,
    }) + '\n');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(reply));
  });
});

server.listen(PORT, () => {
  console.log('gateway mock on ' + PORT);
});
