export async function snapshot(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const zone = await io.fetch('Zone', id);
  if (!zone) return { error: 'NotFound' };
  const key = 'zones/' + id + '.json';
  let body = null;
  try {
    body = await io.blobGet(key);
  } catch {
    return { error: 'NotFound' };
  }
  if (body == null) return { error: 'NotFound' };
  return { result: { key, content: String(body) } };
}
