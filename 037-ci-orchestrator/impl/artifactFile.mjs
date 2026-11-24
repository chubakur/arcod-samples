export async function artifactFile(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Artifact', id);
  if (!found) return { error: 'NotFound' };
  const body = await io.blobGet(found.key);
  if (body == null) return { error: 'NotFound' };
  return { result: { name: found.name, type: 'text/plain; charset=utf-8', body: String(body) } };
}
