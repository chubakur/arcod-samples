export async function latest(input, io) {
  const id = String(input.id || '');
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };
  if (!doc.snapshotKey) return { error: 'NotFound' };

  const body = await io.blobGet(doc.snapshotKey);
  if (body === null) return { error: 'NotFound' };
  const parsed = JSON.parse(body);
  return {
    result: {
      docId: id,
      version: Number(parsed.version) || 0,
      key: doc.snapshotKey,
      content: String(parsed.content || ''),
    },
  };
}
