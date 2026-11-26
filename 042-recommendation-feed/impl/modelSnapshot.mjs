export async function modelSnapshot(input, io) {
  const pointer = await io.load('feed:pointer');
  const p = pointer && pointer.b ? pointer.b : null;
  if (!p || !p.key) return { error: 'NotFound' };
  let body = null;
  try {
    body = await io.blobGet(String(p.key));
  } catch {
    return { error: 'NotFound' };
  }
  if (body == null) return { error: 'NotFound' };
  const text = String(body);
  return {
    result: {
      key: String(p.key),
      version: Number(p.version) || 0,
      bytes: Buffer.byteLength(text, 'utf8'),
      content: text,
    },
  };
}
