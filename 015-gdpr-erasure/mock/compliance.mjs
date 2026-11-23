// The compliance gateway: another company's service that issues the legal
// erasure certificate. It records every request to a log file, and with
// FAIL_FIRST=1 it rejects the first call so the smoke test can see the job
// retry instead of trusting a green checkmark.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const port = Number(process.env.PORT || 9097);
const log = process.env.GATEWAY_LOG || '/tmp/arcod-015-gateway.jsonl';
const failFirst = Number(process.env.FAIL_FIRST || 0);
writeFileSync(log, '');
let calls = 0;

const server = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
    return;
  }
  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', () => {
    if (req.method === 'POST' && req.url === '/v1/certificates') {
      calls += 1;
      let payload = {};
      try { payload = JSON.parse(raw || '{}'); } catch (error) { payload = {}; }
      if (calls <= failFirst) {
        appendFileSync(log, JSON.stringify({ at: new Date().toISOString(), status: 503, payload }) + '\n');
        res.writeHead(503, { 'content-type': 'application/json' });
        res.end('{"error":"temporarily unavailable"}');
        return;
      }
      const certificate = 'CM-' + String(payload.requestId || 'unknown').slice(0, 8).toUpperCase() + '-' + calls;
      appendFileSync(log, JSON.stringify({ at: new Date().toISOString(), status: 200, certificate, payload }) + '\n');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ accepted: true, certificate }));
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"error":"not found"}');
  });
});

server.listen(port, () => {
  console.log('compliance mock on ' + port + ' (failFirst=' + failFirst + ')');
});
