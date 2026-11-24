// A stand-in for an inbound mail provider (Postmark/SendGrid inbound webhook
// or an IMAP poller service). It speaks exactly the routes the spec declares:
// POST /pull answers the messages after a cursor. POST /messages is the test
// hook that injects mail; a real provider would not have it.
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT || 9097);
const mail = [];
let counter = 0;

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
    mail.length = 0;
    counter = 0;
    return reply(res, 200, { ok: true });
  }

  if (req.method === 'POST' && url.pathname === '/messages') {
    const body = await readBody(req);
    counter += 1;
    const item = {
      seq: counter,
      id: 'ext-' + counter,
      mailbox: String(body.mailbox || ''),
      from: String(body.from || 'sender@example.com'),
      to: String(body.mailbox || ''),
      subject: String(body.subject || '(no subject)'),
      receivedAt: Math.floor(Date.now() / 1000),
      text: String(body.text || ''),
      attachments: Array.isArray(body.attachments) ? body.attachments : [],
    };
    mail.push(item);
    return reply(res, 201, { id: item.id, seq: item.seq });
  }

  if (req.method === 'POST' && url.pathname === '/pull') {
    const body = await readBody(req);
    const mailbox = String(body.mailbox || '');
    const after = Number(body.after || 0);
    const items = mail.filter((item) => item.mailbox === mailbox && item.seq > after);
    const cursor = mail
      .filter((item) => item.mailbox === mailbox)
      .reduce((max, item) => Math.max(max, item.seq), after);
    return reply(res, 200, {
      messages: items.map(({ seq, ...rest }) => rest),
      cursor: String(cursor),
    });
  }

  return reply(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log('mock inbox listening on :' + PORT);
});
