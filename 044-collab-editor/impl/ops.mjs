export async function ops(input, io) {
  const id = String(input.id || '');
  const since = Math.max(Number(input.since) || 0, 0);
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };
  const page = await io.find('Op', { where: { docId: id }, order: 'at asc', limit: 5000 });
  const rows = (page.items || []).map((op, index) => ({ ...op, version: index + 1 }));
  return { result: rows.filter((op) => op.version > since) };
}
