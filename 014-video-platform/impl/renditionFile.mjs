// A rendition is addressable by id only: the client never learns the S3 key.
export async function renditionFile(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const found = await io.fetch('Rendition', id);
  if (!found) return { error: 'NotFound' };
  const body = await io.blobGet(found.key);
  if (body == null) return { error: 'NotFound' };
  return { result: { name: found.preset + '.bin', type: 'application/octet-stream', body: String(body) } };
}
