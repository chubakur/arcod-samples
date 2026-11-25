export async function createExport(input, io) {
  const raw = Array.isArray(input.features) ? input.features : [];
  const names = [...new Set(raw.map((n) => String(n).trim()).filter(Boolean))];
  if (names.length === 0 || names.length > 20) return { error: 'Invalid' };

  for (const name of names) {
    const found = await io.find('Feature', { where: { name }, limit: 1 });
    if ((found.items || []).length === 0) return { error: 'Invalid' };
  }

  const fromAt = new Date(String(input.fromAt || ''));
  const toAt = new Date(String(input.toAt || ''));
  if (Number.isNaN(fromAt.getTime()) || Number.isNaN(toAt.getTime())) return { error: 'Invalid' };
  if (toAt.getTime() <= fromAt.getTime()) return { error: 'Invalid' };

  const row = {
    id: await io.new(),
    status: 'queued',
    features: names,
    fromAt: fromAt.toISOString(),
    toAt: toAt.toISOString(),
    rows: 0,
    key: null,
    error: null,
    createdAt: new Date().toISOString(),
    finishedAt: null,
  };
  await io.insert('Export', row);
  await io.queuePublish('exports', { exportId: row.id });
  return { result: row };
}
