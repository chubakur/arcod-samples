// Replay is for a message whose delivery burned its retry budget. A message
// that is queued or already delivered has nothing to replay.
export async function replay(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Message', id);
  if (!found) return { error: 'NotFound' };
  if (found.status === 'ignored') return { error: 'Conflict' };

  const old = await io.find('Delivery', {
    where: { messageId: id },
    order: 'createdAt desc',
    limit: 1,
  });
  const last = (old.items || [])[0];
  if (last && last.status !== 'failed') return { error: 'Conflict' };
  if (!last) return { error: 'Conflict' };

  const delivery = {
    id: await io.new(),
    messageId: id,
    mailboxId: String(found.mailboxId),
    topic: String(found.topic),
    status: 'queued',
    attempts: 0,
    lastError: '',
    createdAt: Date.now(),
    deliveredAt: 0,
  };
  await io.insert('Delivery', delivery);
  await io.update('Message', id, { status: 'ingested' });
  await io.queuePublish('deliver', { deliveryId: delivery.id });
  return { result: delivery };
}
