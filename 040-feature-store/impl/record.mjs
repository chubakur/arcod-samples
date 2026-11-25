// The row is written before the queue message: a lost message costs a
// materialisation retry, a lost row would cost the observation itself.
function valid(dtype, raw) {
  const value = String(raw);
  if (dtype === 'int') return /^-?\d+$/.test(value);
  if (dtype === 'float') return value !== '' && Number.isFinite(Number(value));
  if (dtype === 'bool') return value === 'true' || value === 'false';
  return value.length > 0 && value.length <= 512;
}

export async function record(input, io) {
  const feature = String(input.feature || '').trim();
  const entityId = String(input.entityId || '').trim();
  const value = String(input.value ?? '');
  const atRaw = String(input.at || '').trim();
  if (!feature || !entityId || !value) return { error: 'Invalid' };

  const found = await io.find('Feature', { where: { name: feature }, limit: 1 });
  const def = (found.items || [])[0];
  if (!def) return { error: 'NotFound' };
  if (!valid(String(def.dtype), value)) return { error: 'Invalid' };

  const at = atRaw ? new Date(atRaw) : new Date();
  if (Number.isNaN(at.getTime())) return { error: 'Invalid' };

  const event = {
    id: await io.new(),
    feature,
    entityId,
    value,
    at: at.toISOString(),
    ingestedAt: new Date().toISOString(),
    version: Number(def.version || 1),
    materialized: false,
    offKey: null,
  };
  await io.insert('Event', event);
  await io.queuePublish('events', { eventId: event.id });
  return { result: event };
}
