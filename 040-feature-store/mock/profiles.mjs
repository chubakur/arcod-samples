// The profile service is somebody else's system: this stub stands in for it in
// smoke. /fail makes every entity whose id starts with "fail-" answer 500,
// /heal turns the failure off, /ok is a liveness probe.
import http from 'node:http';
import fs from 'node:fs';

const port = Number(process.env.PROFILES_PORT || process.env.PORT || 9098);
const log = process.env.PROFILES_LOG || '/tmp/arcod-040-profiles.log';
let failing = true;

const server = http.createServer((req, res) => {
  if (req.url === '/ok') {
    res.end('{"ok":true}');
    return;
  }
  if (req.url === '/heal') {
    failing = false;
    res.end('{"healed":true}');
    return;
  }
  if (req.url === '/fail') {
    failing = true;
    res.end('{"failing":true}');
    return;
  }

  let body = '';
  req.on('data', (chunk) => (body += chunk));
  req.on('end', () => {
    let entityId = '';
    try {
      entityId = JSON.parse(body || '{}').entityId || '';
    } catch {}
    fs.appendFileSync(log, entityId + '\n');
    if (failing && String(entityId).startsWith('fail-')) {
      res.statusCode = 500;
      res.end('{"error":"profile service down"}');
      return;
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ entityId, segment: 'enterprise', country: 'RU', plan: 'pro' }));
  });
});

server.listen(port, '0.0.0.0', () => console.log('profiles mock on :' + port));
