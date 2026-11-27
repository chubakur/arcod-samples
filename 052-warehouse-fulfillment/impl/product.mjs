export async function product(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const id = String(body.productId || '');
  const row = await io.fetch('Product', id);
  if (!row) return { error: 'NotFound' };
  const batches = await io.find('Batch', { where: { productId: id }, order: 'expiresAt asc', limit: 200 });
  return { result: { product: row, batches: batches.items || [] } };
}
