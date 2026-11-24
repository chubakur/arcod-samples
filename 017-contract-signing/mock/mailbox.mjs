// Stand-in for the mail gateway on the compose network. It keeps what it was
// asked to send so the smoke script can read the invitation code back.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const messages = [];

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const send = (status, body) => {
    const payload = JSON.stringify(body);
    res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
    res.end(payload);
  };

  if (req.method === 'GET' && url.pathname === '/healthz') return send(200, { ok: true });

  if (req.method === 'GET' && url.pathname === '/api/v1/messages') {
    const to = (url.searchParams.get('to') || '').toLowerCase();
    const rows = to ? messages.filter((m) => m.to.toLowerCase() === to) : messages;
    return send(200, { messages: rows });
  }

  if (req.method === 'DELETE' && url.pathname === '/api/v1/messages') {
    messages.length = 0;
    return send(200, { ok: true });
  }

  if (req.method === 'POST' && url.pathname === '/api/v1/send') {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      let input = {};
      try { input = JSON.parse(raw || '{}'); } catch { return send(400, { error: 'Invalid' }); }
      if (!input.to || !input.subject) return send(400, { error: 'Invalid' });
      const id = randomUUID();
      messages.push({ id, from: input.from || '', to: String(input.to), subject: String(input.subject), text: String(input.text || ''), at: new Date().toISOString() });
      send(201, { id });
    });
    return;
  }

  send(404, { error: 'NotFound' });
});

server.listen(9097, () => console.log('mailbox on 9097'));
