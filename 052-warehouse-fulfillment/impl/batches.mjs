export async function batches(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const where = {};
  if (body.productId) where.productId = String(body.productId);
  if (body.status) where.status = String(body.status);
  const page = await io.find('Batch', { where, order: 'expiresAt asc', limit: 200 });
  return { result: page.items || [] };
}
