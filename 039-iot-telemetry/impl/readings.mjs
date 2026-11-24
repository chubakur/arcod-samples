export async function readings(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const device = await io['fetch']('Device', id);
  if (!device) return { error: 'NotFound' };

  const limit = Math.min(Math.max(Number(input.limit) || 50, 1), 200);
  const where = { deviceId: id };
  const metric = String(input.metric || '').trim();
  if (metric) where.metric = metric;

  const found = await io.find('Reading', { where, limit: 200 });
  const items = (found.items || [])
    .slice()
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at))
    .slice(0, limit);
  return { result: items };
}
