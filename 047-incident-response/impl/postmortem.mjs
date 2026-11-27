export async function postmortem(input, io) {
  const id = String(input.id || '');
  const row = await io.fetch('Incident', id);
  if (!row) return { error: 'NotFound', id };
  if (!row.postmortemKey) return { error: 'NotFound', id };
  const body = await io.blobGet(row.postmortemKey);
  const content = String(body || '');
  return { result: { key: row.postmortemKey, content, bytes: content.length } };
}
