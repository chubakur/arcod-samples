export async function replenishments(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const where = {};
  if (body.status) where.status = String(body.status);
  const page = await io.find('Replenishment', { where, order: 'sku asc', limit: 200 });
  return { result: page.items || [] };
}
