export async function getExport(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const rec = await io['fetch']('ExportRec', id);
  if (!rec) return { error: 'NotFound' };
  const body = await io.blobGet(rec.objectKey);
  if (body == null) return { error: 'NotFound' };
  return { result: { rec, body: String(body) } };
}
