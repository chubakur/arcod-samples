// One delivery, one signed payload. The signature covers the fields the
// subscriber is about to trust, so a body swap after the fact breaks it.
const MAX_ATTEMPTS = 3;

function deliverHex(buffer) {
  return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function deliverSign(secret, text) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(String(secret)),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return deliverHex(await crypto.subtle.sign('HMAC', key, encoder.encode(text)));
}

export async function deliver(input, io) {
  const deliveryId = String(input.deliveryId || '');
  const delivery = await io.fetch('Delivery', deliveryId);
  if (!delivery) return { ok: true, skipped: 'delivery is gone' };
  if (delivery.status === 'delivered') return { ok: true, skipped: true };

  const message = await io.fetch('Message', String(delivery.messageId));
  const mailbox = await io.fetch('Mailbox', String(delivery.mailboxId));
  if (!message || !mailbox) return { ok: true, skipped: 'source is gone' };

  const found = await io.find('Attachment', {
    where: { messageId: String(message.id) },
    order: 'name asc',
    limit: 50,
  });
  const attempts = Number(delivery.attempts || 0) + 1;
  const canonical = [
    deliveryId,
    String(message.id),
    String(mailbox.address),
    String(delivery.topic),
    String(message.fromAddress),
    String(message.subject),
    String(message.receivedAt),
    String(message.bodyKey),
  ].join('\n');

  const payload = {
    deliveryId,
    messageId: String(message.id),
    mailbox: String(mailbox.address),
    topic: String(delivery.topic),
    from: String(message.fromAddress),
    subject: String(message.subject),
    receivedAt: Number(message.receivedAt || 0),
    bodyKey: String(message.bodyKey),
    bodyBytes: Number(message.bodyBytes || 0),
    attachments: (found.items || []).map((item) => ({
      name: String(item.name),
      contentType: String(item.contentType),
      key: String(item.key),
      bytes: Number(item.bytes || 0),
      sha256: String(item.sha256),
    })),
    signature: await deliverSign(String(mailbox.secret), canonical),
  };

  try {
    const reply = await io.remote('Sink', 'deliver', payload);
    if (!reply || Number(reply.status) >= 400) {
      throw new Error('sink answered ' + (reply ? reply.status : 'nothing'));
    }
    await io.update('Delivery', deliveryId, {
      status: 'delivered',
      attempts,
      lastError: '',
      deliveredAt: Date.now(),
    });
    await io.update('Message', String(message.id), { status: 'delivered' });
  } catch (error) {
    const text = String((error && error.message) || error).slice(0, 200);
    const final = attempts >= MAX_ATTEMPTS;
    await io.update('Delivery', deliveryId, {
      status: final ? 'failed' : 'retrying',
      attempts,
      lastError: text,
    });
    if (final) await io.update('Message', String(message.id), { status: 'failed' });
    throw error;
  }

  return { ok: true, attempts, topic: payload.topic };
}
