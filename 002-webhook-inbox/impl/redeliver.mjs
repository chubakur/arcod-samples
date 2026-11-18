export async function redeliver(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'Invalid' };
  const found = await io.find('Event', { where: { id }, limit: 1 });
  const event = (found.items || [])[0];
  if (!event) return { error: 'NotFound' };

  // A redelivery is an operator retry: reset the counter and clear the fault
  // injection, as if the subscriber endpoint had been fixed.
  const next = { attempts: 0, status: 'pending', failFirst: 0, deliveredAt: null };
  const updated = await io.update('Event', id, next);
  await io.queuePublish('deliveries', id);
  return { result: Object.assign({}, event, next, updated || {}) };
}
