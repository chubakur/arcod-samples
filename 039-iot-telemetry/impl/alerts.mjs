export async function alerts(input, io) {
  const status = String(input.status || 'open').trim();
  const limit = Math.min(Math.max(Number(input.limit) || 50, 1), 200);
  const where = status === 'all' ? {} : { status };

  const found = await io.find('Alert', { where, limit: 200 });
  const total = await io.count('Alert', { where });
  const items = (found.items || [])
    .slice()
    .sort((a, b) => Date.parse(b.openedAt) - Date.parse(a.openedAt))
    .slice(0, limit);
  return { result: { items, total } };
}
