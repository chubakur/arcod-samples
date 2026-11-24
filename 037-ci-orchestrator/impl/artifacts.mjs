export async function artifacts(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Run', id);
  if (!found) return { error: 'NotFound' };
  const page = await io.find('Artifact', { where: { runId: id }, order: 'createdAt asc', limit: 200 });
  const items = page.items || [];
  return { result: { items, total: items.length } };
}
