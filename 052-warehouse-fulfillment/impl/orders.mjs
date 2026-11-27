export async function orders(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const limit = Number(body.limit == null ? 50 : body.limit);
  if (!Number.isInteger(limit) || limit <= 0 || limit > 200) return { error: 'Invalid' };
  const where = {};
  if (body.status) where.status = String(body.status);
  const page = await io.find('SalesOrder', { where, order: 'createdAt desc', limit });
  return { result: page.items || [] };
}
