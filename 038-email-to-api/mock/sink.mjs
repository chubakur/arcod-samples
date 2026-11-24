// A stand-in for a subscriber's webhook endpoint. It records every signed
// payload and can be told to fail the next N calls, which is how the smoke
// test walks the retry path and then the dead letter.
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT || 9098);
const deliveries = [];
let failTimes = 0;

function reply(res, code, body) {
  const text = JSON.stringify(body);
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  res.end(text);
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    return {};
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  if (req.method === 'GET' && url.pathname === '/healthz') return reply(res, 200, { ok: true });

  if (req.method === 'POST' && url.pathname === '/reset') {
    deliveries.length = 0;
    failTimes = 0;
    return reply(res, 200, { ok: true });
  }

  if (req.method === 'POST' && url.pathname === '/fail') {
    const body = await readBody(req);
    failTimes = Math.max(0, Number(body.times || 0));
    return reply(res, 200, { failTimes });
  }

  if (req.method === 'GET' && url.pathname === '/deliveries') {
    return reply(res, 200, { deliveries, failTimes });
  }

  if (req.method === 'POST' && url.pathname === '/hooks/email') {
    const body = await readBody(req);
    if (failTimes > 0) {
      failTimes -= 1;
      return reply(res, 503, { error: 'subscriber is down' });
    }
    deliveries.push({ at: Date.now(), payload: body });
    return reply(res, 200, { received: true, id: 'sink-' + deliveries.length });
  }

  return reply(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log('mock sink listening on :' + PORT);
});
