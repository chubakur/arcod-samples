export async function invoice(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const inv = await io.fetch('Invoice', id);
  if (!inv) return { error: 'NotFound' };
  return { result: inv };
}
