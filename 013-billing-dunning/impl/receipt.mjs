export async function receipt(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const inv = await io.fetch('Invoice', id);
  if (!inv || !inv.receiptKey) return { error: 'NotFound' };
  const body = await io.blobGet(String(inv.receiptKey));
  if (body == null) return { error: 'NotFound' };
  return { result: String(body) };
}
