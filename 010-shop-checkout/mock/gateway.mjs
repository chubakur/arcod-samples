// A stand-in for the payment provider. Arcod never generates it: the gateway is
// somebody else's service, we only bind its address in the spec.
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT || 9099);
let seq = 0;

const server = createServer((req, res) => {
  const send = (code, body) => {
    const text = JSON.stringify(body);
    res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
    res.end(text);
  };

  if (req.method === 'GET' && req.url === '/healthz') return send(200, { ok: true });
  if (req.method !== 'POST' || req.url !== '/v1/charges') return send(404, { error: 'not found' });

  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', () => {
    let body = {};
    try { body = JSON.parse(raw || '{}'); } catch { return send(400, { error: 'bad json' }); }
    const amount = Number(body.amount);
    if (!Number.isInteger(amount) || amount <= 0) return send(400, { error: 'bad amount' });
    if (String(body.token) === 'decline') return send(200, { ref: 'ch_declined_' + (++seq), approved: false });
    return send(200, { ref: 'ch_' + (++seq), approved: true });
  });
});

server.listen(PORT, '0.0.0.0', () => console.log('mock gateway on ' + PORT));
