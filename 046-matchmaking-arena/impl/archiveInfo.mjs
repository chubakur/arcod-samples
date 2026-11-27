export async function archiveInfo(input, io) {
  const id = String(input.id || '');
  const match = await io.fetch('ArenaMatch', id);
  if (!match || !match.archiveKey) return { error: 'NotFound', id };
  const content = await io.blobGet(match.archiveKey);
  if (content == null) return { error: 'NotFound', id };
  return { result: { key: match.archiveKey, content, bytes: content.length } };
}
