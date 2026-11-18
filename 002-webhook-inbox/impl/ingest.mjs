export async function ingest(input, io) {
  const source = String(input.source || '').trim();
  const key = String(input.key || '').trim();
  const eventType = String(input.eventType || '').trim();
  const payload = String(input.payload == null ? '' : input.payload);
  const failFirst = input.failFirst == null ? 0 : Number(input.failFirst);

  if (source.length < 1 || source.length > 64) return { error: 'Invalid' };
  if (key.length < 1 || key.length > 200) return { error: 'Invalid' };
  if (eventType.length < 1 || eventType.length > 100) return { error: 'Invalid' };
  if (payload.length > 65536) return { error: 'Invalid' };
  if (!Number.isInteger(failFirst) || failFirst < 0 || failFirst > 10) return { error: 'Invalid' };

  // Idempotency: the pair (source, key) is the sender's stable event id.
  const idemKey = 'k:' + source + ':' + key;
  const seen = await io.load(idemKey);
  if (seen && seen.b) {
    const found = await io.find('Event', { where: { id: String(seen.b) }, limit: 1 });
    const existing = (found.items || [])[0];
    if (existing) return { result: { event: existing, duplicate: true } };
  }

  const id = await io.new();
  const event = {
    id,
    source,
    key,
    eventType,
    payload,
    status: 'pending',
    attempts: 0,
    failFirst,
    receivedAt: new Date().toISOString(),
    deliveredAt: null,
  };

  await io.insert('Event', event);
  await io.save(idemKey, { b: id, h: null });
  await io.queuePublish('deliveries', id);

  return { result: { event, duplicate: false } };
}
