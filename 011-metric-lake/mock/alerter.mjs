// Stand-in for the on-call alerting service. Arcod never generates it: we only
// bind its address in the spec.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const PORT = Number(process.env.PORT || 9099);
const FILE = process.env.ALERTS_FILE || '/tmp/arcod-011-alerts.jsonl';
writeFileSync(FILE, '');

const server = createServer((req, res) => {
  const send = (code, body) => {
    const text = JSON.stringify(body);
    res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
    res.end(text);
  };

  if (req.method === 'GET' && req.url === '/healthz') return send(200, { ok: true });
  if (req.method === 'GET' && req.url === '/v1/alerts') {
    return send(200, { file: FILE });
  }

  if (req.method === 'POST' && req.url === '/v1/alerts') {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 65536) req.destroy();
    });
    req.on('end', () => {
      let body = {};
      try {
        body = JSON.parse(raw || '{}');
      } catch {
        return send(400, { ok: false, ref: '' });
      }
      appendFileSync(FILE, JSON.stringify(body) + '\n');
      return send(202, { ok: true, ref: String(body.id || '') });
    });
    return undefined;
  }

  return send(404, { ok: false, ref: '' });
});

server.listen(PORT, '0.0.0.0', () => {
  process.stdout.write('alert mock on ' + PORT + '\n');
});
