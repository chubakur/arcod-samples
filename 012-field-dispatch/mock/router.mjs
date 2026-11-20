// Stand-in for the routing / SMS gateway. Arcod binds its address in the spec;
// the service itself stays external.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const PORT = Number(process.env.PORT || 9098);
const FILE = process.env.ROUTER_FILE || '/tmp/arcod-012-router.jsonl';
writeFileSync(FILE, '');

const server = createServer((req, res) => {
  const send = (code, body) => {
    const text = JSON.stringify(body);
    res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
    res.end(text);
  };

  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', () => {
    let body = {};
    try { body = raw ? JSON.parse(raw) : {}; } catch { return send(400, { ok: false, ref: '' }); }
    const path = (req.url || '').split('?')[0];

    if (req.method === 'POST' && path === '/v1/offers') {
      appendFileSync(FILE, JSON.stringify({ kind: 'offer', body }) + '\n');
      const eta = 15 + (Number(body.priority || 1) * 10);
      return send(200, { accepted: true, technician: 'auto', eta });
    }

    if (req.method === 'POST' && path === '/v1/notify') {
      appendFileSync(FILE, JSON.stringify({ kind: 'notify', body }) + '\n');
      return send(202, { ok: true, ref: String(body.ticketId || '') });
    }

    if (req.method === 'GET' && path === '/healthz') return send(200, { ok: true });

    return send(404, { ok: false, ref: '' });
  });
});

server.listen(PORT, '0.0.0.0', () => {
  process.stdout.write('router mock on ' + PORT + '\n');
});
