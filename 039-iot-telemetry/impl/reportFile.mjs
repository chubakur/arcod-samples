export async function reportFile(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const row = await io['fetch']('Report', id);
  if (!row) return { error: 'NotFound' };

  const body = await io.blobGet(row.key);
  if (body == null) return { error: 'NotFound' };
  return { result: { key: row.key, content: String(body) } };
}
