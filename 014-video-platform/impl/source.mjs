// Bytes leave through the service: the bucket has no public policy, and the
// key stays a server-side detail.
export async function source(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const found = await io.fetch('Video', id);
  if (!found) return { error: 'NotFound' };
  const body = await io.blobGet(found.sourceKey);
  if (body == null) return { error: 'NotFound' };
  return { result: { name: found.title + '-source.bin', type: found.contentType, body: String(body) } };
}
