// A stand-in for a build machine. It speaks exactly the route the spec
// declares and turns command text into a deterministic result: "fail" exits 1,
// "slow" sleeps long enough for the smoke test to cancel, "artifact" produces
// a file the orchestrator has to put in object storage.
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT || 9095);

function reply(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

const server = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }
  if (req.method !== 'POST' || req.url !== '/execute') {
    reply(res, 404, { error: 'not found' });
    return;
  }

  let raw = '';
  req.on('data', (chunk) => { raw += chunk; });
  req.on('end', async () => {
    let body = {};
    try { body = JSON.parse(raw || '{}'); } catch { body = {}; }
    const command = String(body.command || '');
    const started = Date.now();

    if (command.indexOf('fail') === 0) {
      reply(res, 200, {
        exitCode: 1,
        stdout: 'step started\n',
        stderr: 'compilation failed: unexpected token\n',
        durationMs: Date.now() - started,
        artifacts: [],
      });
      return;
    }

    if (command.indexOf('slow') === 0) {
      await new Promise((resolve) => setTimeout(resolve, 2500));
      reply(res, 200, {
        exitCode: 0,
        stdout: 'slow step done\n',
        stderr: '',
        durationMs: Date.now() - started,
        artifacts: [],
      });
      return;
    }

    if (command.indexOf('artifact') === 0) {
      reply(res, 200, {
        exitCode: 0,
        stdout: 'wrote report.txt\n',
        stderr: '',
        durationMs: Date.now() - started,
        artifacts: [{ name: 'report.txt', content: 'all green\n42 tests passed\n' }],
      });
      return;
    }

    reply(res, 200, {
      exitCode: 0,
      stdout: 'simulated: ' + command + '\n',
      stderr: '',
      durationMs: Date.now() - started,
      artifacts: [],
    });
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('runner listening on ' + PORT);
});
