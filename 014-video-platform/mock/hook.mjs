// The webhook the platform calls when a video is ready. It records every body
// to a log file so the smoke test can prove the consumer really left the
// process instead of writing the delivery row and hoping.
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';

const port = Number(process.env.PORT || 9098);
const log = process.env.HOOK_LOG || '/tmp/arcod-014-hook.jsonl';
writeFileSync(log, '');

const server = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
    return;
  }
  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', () => {
    if (req.method === 'POST' && req.url === '/v1/ready') {
      appendFileSync(log, raw + '\n');
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end('{"received":true}');
      return;
    }
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end('{"error":"NotFound"}');
  });
});

server.listen(port, () => console.log('hook mock on :' + port + ', log ' + log));
