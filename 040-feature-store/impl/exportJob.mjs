export async function exportJob(input, io) {
  const id = String(input.id || '').trim();
  if (!id) return { error: 'NotFound' };
  const row = await io.fetch('Export', id);
  if (!row) return { error: 'NotFound' };
  return { result: row };
}
