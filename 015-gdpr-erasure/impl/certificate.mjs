export async function certificate(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const record = await io.fetch('ErasureRequest', id);
  if (!record || !record.reportKey) return { error: 'NotFound' };

  const body = await io.blobGet(record.reportKey);
  if (body == null) return { error: 'NotFound' };
  return {
    result: {
      name: 'erasure-' + id + '.json',
      type: 'application/json',
      body: String(body)
    }
  };
}
