// The ingest job is idempotent: the external id plus mailbox is the key, so a
// redelivered job after a crash rewrites the same S3 object at worst and
// inserts nothing twice.
function ingestHex(buffer) {
  return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function ingestSha256(value) {
  const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : value;
  return ingestHex(await crypto.subtle.digest('SHA-256', bytes));
}

function base64Bytes(text) {
  const bin = atob(String(text || ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}

function ingestMatches(route, raw) {
  if (!route.active) return false;
  const from = String(raw.from || '').toLowerCase();
  const subject = String(raw.subject || '').toLowerCase();
  if (route.fromContains && from.indexOf(String(route.fromContains)) < 0) return false;
  if (route.subjectContains && subject.indexOf(String(route.subjectContains)) < 0) return false;
  return true;
}

export async function ingest(input, io) {
  const mailboxId = String(input.mailboxId || '');
  const mailbox = await io.fetch('Mailbox', mailboxId);
  if (!mailbox) return { ok: true, skipped: 'mailbox is gone' };
  if (!mailbox.active) return { ok: true, skipped: 'mailbox is paused' };

  const answer = await io.remote('Inbox', 'pull', {
    mailbox: String(mailbox.address),
    after: String(mailbox.cursor || '0'),
  });
  if (!answer || Number(answer.status) >= 400) {
    throw new Error('inbox answered ' + (answer ? answer.status : 'nothing'));
  }

  const body = answer.body || {};
  const batch = Array.isArray(body.messages) ? body.messages : [];
  const found = await io.find('Route', { where: { mailboxId }, order: 'createdAt asc', limit: 50 });
  const routes = found.items || [];

  let ingested = 0;
  for (const raw of batch) {
    const externalId = String((raw && raw.id) || '').trim();
    if (!externalId) continue;

    const seen = await io.find('Message', { where: { mailboxId, externalId }, limit: 1 });
    if ((seen.items || []).length > 0) continue;

    const text = String(raw.text || '');
    const messageId = await io.new();
    const bodyKey = 'mail/' + mailboxId + '/' + externalId + '/body.txt';
    await io.blobPut(bodyKey, text, 'text/plain; charset=utf-8');

    const route = routes.find((item) => ingestMatches(item, raw));
    const topic = route ? String(route.topic) : 'unmatched';
    const status = route ? 'ingested' : 'ignored';
    const attachments = Array.isArray(raw.attachments) ? raw.attachments : [];

    await io.insert('Message', {
      id: messageId,
      mailboxId,
      externalId,
      fromAddress: String(raw.from || ''),
      toAddress: String(raw.to || ''),
      subject: String(raw.subject || '').slice(0, 300),
      receivedAt: Number(raw.receivedAt || 0),
      bodyKey,
      bodyBytes: new TextEncoder().encode(text).length,
      digest: await ingestSha256(text),
      attachmentCount: attachments.length,
      topic,
      status,
      createdAt: Date.now(),
    });

    let index = 0;
    for (const att of attachments) {
      const bytes = base64Bytes(att && att.contentBase64);
      const key = 'mail/' + mailboxId + '/' + externalId + '/att/' + index + '.bin';
      // The blob port takes text, so the object is base64 with an explicit
      // encoding hint; the row carries the decoded size and digest.
      await io.blobPut(key, String((att && att.contentBase64) || ''), 'application/octet-stream; encoding=base64');
      await io.insert('Attachment', {
        id: await io.new(),
        messageId,
        name: String((att && att.name) || 'attachment-' + index),
        contentType: String((att && att.contentType) || 'application/octet-stream'),
        key,
        bytes: bytes.length,
        sha256: await ingestSha256(bytes),
      });
      index += 1;
    }

    if (route) {
      const delivery = {
        id: await io.new(),
        messageId,
        mailboxId,
        topic,
        status: 'queued',
        attempts: 0,
        lastError: '',
        createdAt: Date.now(),
        deliveredAt: 0,
      };
      await io.insert('Delivery', delivery);
      await io.queuePublish('deliver', { deliveryId: delivery.id });
    }
    ingested += 1;
  }

  await io.update('Mailbox', mailboxId, { cursor: String(body.cursor || mailbox.cursor || '0') });
  return { ok: true, ingested };
}
