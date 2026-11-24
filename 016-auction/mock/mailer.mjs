// A stand-in for the mail vendor: it accepts the vendor's send call, keeps the
// message in memory and exposes the mailbox, so the smoke test can prove that
// the consumer really mailed the seller and the winner.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.PORT || 9096);
const messages = [];

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const send = (code, body) => {
    const text = JSON.stringify(body);
    res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
    res.end(text);
  };

  if (req.method === 'GET' && url.pathname === '/healthz') return send(200, { ok: true });
  if (req.method === 'GET' && url.pathname === '/api/v1/messages') {
    return send(200, { total: messages.length, messages });
  }
  if (req.method === 'POST' && url.pathname === '/api/v1/send') {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      let body;
      try { body = JSON.parse(raw || '{}'); } catch { return send(400, { error: 'bad json' }); }
      if (!body.to || !body.subject || !body.text) return send(422, { error: 'to, subject and text are required' });
      const message = { id: randomUUID(), from: body.from || 'auction@arcod.test', to: body.to, subject: body.subject, text: body.text, at: Date.now() };
      messages.push(message);
      console.log(JSON.stringify({ level: 'mail', ...message }));
      send(200, { id: message.id });
    });
    return undefined;
  }
  send(404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(JSON.stringify({ level: 'info', message: 'mailer mock listening on ' + PORT }));
});
