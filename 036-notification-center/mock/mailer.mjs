// A stand-in for the vendor's send API. It speaks the two routes the spec
// declares, keeps messages in memory for the smoke test, and fails every
// address on bounce.test so a retry path can be exercised deterministically.
import { createServer } from 'node:http';

const messages = [];
let seq = 0;

const server = createServer((req, res) => {
  const send = (status, body, type) => {
    const text = type === 'text' ? body : JSON.stringify(body);
    res.writeHead(status, { 'content-type': type || 'application/json' });
    res.end(text);
  };

  if (req.method === 'GET' && req.url === '/healthz') return send(200, { status: 'ok' });
  if (req.method === 'GET' && req.url === '/api/v1/messages') {
    return send(200, { total: messages.length, messages });
  }

  if (req.method === 'POST' && req.url === '/api/v1/send') {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      let payload = {};
      try { payload = JSON.parse(raw || '{}'); } catch { return send(400, { error: 'bad json' }); }
      const to = String(payload.to || '');
      if (!to.includes('@')) return send(400, { error: 'bad recipient' });
      if (to.endsWith('@bounce.test')) return send(500, { error: 'mailbox unavailable' });
      seq += 1;
      const message = { id: 'msg-' + seq, from: payload.from, to, subject: payload.subject, text: payload.text };
      messages.push(message);
      send(202, { id: message.id });
    });
    return;
  }

  send(404, { error: 'not found' });
});

server.listen(9096, () => console.log('mailer listening on 9096'));
