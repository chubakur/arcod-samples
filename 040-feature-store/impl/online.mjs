// The online value is the last materialised observation, not the last
// ingested one: until the consumer catches up the cache is honestly behind.
export async function online(input, io) {
  const feature = String(input.feature || '').trim();
  const entityId = String(input.entityId || '').trim();
  if (!feature || !entityId) return { error: 'NotFound' };

  const found = await io.find('Feature', { where: { name: feature }, limit: 1 });
  const def = (found.items || [])[0];
  if (!def) return { error: 'NotFound' };

  const record = await io.load('f:' + feature + ':' + entityId);
  const rec = record && record.b ? record.b : null;
  if (!rec || rec.value === undefined) return { error: 'NotFound' };

  const ageSeconds = Math.max(0, Math.round((Date.now() - Date.parse(rec.at)) / 1000));
  return {
    result: {
      feature,
      entityId,
      value: String(rec.value),
      at: rec.at,
      version: Number(rec.version || 1),
      ageSeconds,
      stale: ageSeconds > Number(def.ttlSeconds || 0),
    },
  };
}
