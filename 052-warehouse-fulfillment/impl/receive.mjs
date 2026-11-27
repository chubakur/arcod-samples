// Inbound lot. The batch row is the fact; onHand is the running total the
// catalogue reads. The restock publish is the only thing the warehouse is
// waiting for: an order that was short of this SKU can now allocate.
export async function receive(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const productId = String(body.productId || '');
  const code = String(body.code || '').trim().toUpperCase();
  const qty = Number(body.qty);
  const bin = String(body.bin || 'A-01').trim().toUpperCase();
  const expiresAt = String(body.expiresAt || '');
  if (!code || !Number.isInteger(qty) || qty <= 0) return { error: 'Invalid' };
  if (!Number.isFinite(Date.parse(expiresAt))) return { error: 'Invalid' };
  if (!bin) return { error: 'Invalid' };

  const product = await io.fetch('Product', productId);
  if (!product) return { error: 'NotFound' };

  const prior = await io.find('Batch', { where: { code }, limit: 1 });
  if ((prior.items || []).length > 0) return { error: 'Conflict' };

  const now = new Date().toISOString();
  const batch = {
    id: await io.new(),
    productId,
    code,
    bin,
    qty,
    remaining: qty,
    status: 'open',
    expiresAt: new Date(expiresAt).toISOString(),
    receivedAt: now,
  };
  await io.insert('Batch', batch);
  await io.insert('Movement', {
    id: await io.new(),
    productId,
    batchId: batch.id,
    kind: 'receipt',
    qty,
    ref: code,
    createdAt: now,
  });
  await io.update('Product', productId, { onHand: Number(product.onHand || 0) + qty });
  await io.publish('ops', { type: 'stock', event: 'received', productId, sku: product.sku, qty, bin });
  await io.queuePublish('restock', productId);
  return { result: batch };
}
