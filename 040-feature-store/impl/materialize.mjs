// Offline first, online second: the immutable object is the source of truth,
// the cache is a projection of it.
export async function materialize(input, io) {
  const id = String(input.eventId || '').trim();
  if (!id) return { result: true };

  const event = await io.fetch('Event', id);
  if (!event) return { result: true };
  if (event.materialized) return { result: true };

  const day = String(event.at || '').slice(0, 10) || 'unknown';
  const key = 'offline/' + event.feature + '/' + day + '/' + id + '.json';
  await io.blobPut(
    key,
    JSON.stringify({
      eventId: id,
      feature: event.feature,
      entityId: event.entityId,
      value: String(event.value),
      at: event.at,
      version: Number(event.version || 1),
    }),
  );

  const cacheKey = 'f:' + event.feature + ':' + event.entityId;
  const record = await io.load(cacheKey);
  const prev = record && record.b ? record.b : null;
  if (!prev || Date.parse(event.at) >= Date.parse(prev.at)) {
    await io.save(cacheKey, {
      b: {
        value: String(event.value),
        at: event.at,
        version: Number(event.version || 1),
        eventId: id,
      },
      h: null,
    });
  }

  await io.update('Event', id, { materialized: true, offKey: key });
  return { result: true };
}
