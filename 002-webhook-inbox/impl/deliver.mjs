const MAX_ATTEMPTS = 3;

export async function deliver(input, io) {
  const eventId = String(input.eventId || '');
  if (!eventId) return { result: 'ignored' };

  const found = await io.find('Event', { where: { id: eventId }, limit: 1 });
  const event = (found.items || [])[0];
  if (!event) return { result: 'missing' };

  const attempts = Number(event.attempts || 0) + 1;
  const failFirst = Number(event.failFirst || 0);
  const willFail = attempts <= failFirst;

  // The last allowed attempt is recorded as dead so the API shows the same
  // state the broker will reach when it moves the message to the DLQ.
  const status = willFail ? (attempts >= MAX_ATTEMPTS ? 'dead' : 'retrying') : 'delivered';
  const deliveredAt = willFail ? null : new Date().toISOString();

  await io.update('Event', eventId, { attempts, status, deliveredAt });
  if (willFail) return { error: 'Transient' };
  return { result: { eventId, attempts, deliveredAt } };
}
