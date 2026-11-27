// Catalogue entry. sku is the natural key the checkout uses; a duplicate is a
// conflict, not a second product.
export async function createProduct(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const sku = String(body.sku || '').trim().toLowerCase();
  const name = String(body.name || '').trim();
  const reorderPoint = Number(body.reorderPoint == null ? 0 : body.reorderPoint);
  if (!sku || !/^[a-z0-9][a-z0-9-]{1,39}$/.test(sku) || !name) return { error: 'Invalid' };
  if (!Number.isInteger(reorderPoint) || reorderPoint < 0) return { error: 'Invalid' };

  const prior = await io.find('Product', { where: { sku }, limit: 1 });
  if ((prior.items || []).length > 0) return { error: 'Conflict' };

  const product = {
    id: await io.new(),
    sku,
    name,
    reorderPoint,
    onHand: 0,
    reserved: 0,
    active: true,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Product', product);
  return { result: product };
}
