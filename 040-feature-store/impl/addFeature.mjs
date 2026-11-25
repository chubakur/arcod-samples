// A feature is a definition, not a value: the row names the type and the
// staleness budget, while values live in events and in the online cache.
const DTYPES = new Set(['int', 'float', 'string', 'bool']);

export async function addFeature(input, io) {
  const name = String(input.name || '').trim();
  const dtype = String(input.dtype || '').trim();
  const description = String(input.description || '').trim();
  const ttlSeconds = Number(input.ttlSeconds || 0);

  if (!/^[a-z][a-z0-9_]{1,40}$/.test(name)) return { error: 'Invalid' };
  if (!DTYPES.has(dtype)) return { error: 'Invalid' };
  if (!Number.isFinite(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > 31536000) return { error: 'Invalid' };

  const existing = await io.find('Feature', { where: { name }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const now = new Date().toISOString();
  const feature = {
    id: await io.new(),
    name,
    dtype,
    version: 1,
    description,
    ttlSeconds: Math.round(ttlSeconds),
    status: 'active',
    createdAt: now,
    updatedAt: now,
  };
  await io.insert('Feature', feature);
  return { result: feature };
}
