// One planner pass, driven by an explicit instant (no cron in the language,
// #12). Three jobs in one run:
//   1. write off expired lots that still have units on the shelf;
//   2. propose replenishment for every SKU at or below its reorder point;
//   3. wake backordered orders that can now be filled.
const WFL_DAY_MS = 24 * 60 * 60 * 1000;

export async function runPlanner(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const nowMs = body.now ? Date.parse(String(body.now)) : Date.now();
  if (!Number.isFinite(nowMs)) return { error: 'Invalid' };

  // 1. Expired lots. A lot with a held reservation is not written off: the
  // units are already promised to an order, shipping or cancellation decides.
  const openLots = await io.find('Batch', { where: { status: 'open' }, order: 'expiresAt asc', limit: 500 });
  let expired = 0;
  let writtenOff = 0;
  for (const batch of openLots.items || []) {
    const remaining = Number(batch.remaining || 0);
    if (remaining <= 0) continue;
    const expires = Date.parse(batch.expiresAt);
    if (!Number.isFinite(expires) || expires >= nowMs) continue;
    const held = await io.find('Reservation', { where: { batchId: batch.id, status: 'held' }, limit: 1 });
    if ((held.items || []).length > 0) continue;
    await io.update('Batch', batch.id, { status: 'expired' });
    const product = await io.fetch('Product', batch.productId);
    if (product) {
      await io.update('Product', product.id, {
        onHand: Math.max(0, Number(product.onHand || 0) - remaining),
      });
    }
    await io.insert('Movement', {
      id: await io.new(),
      productId: batch.productId,
      batchId: batch.id,
      kind: 'writeoff',
      qty: -remaining,
      ref: 'expired',
      createdAt: new Date(nowMs).toISOString(),
    });
    expired += 1;
    writtenOff += remaining;
  }

  // 2. Replenishment. unique Replenishment.productId turns a repeated pass
  // into an update instead of a second proposal.
  const productPage = await io.find('Product', { where: { active: true }, limit: 500 });
  let proposals = 0;
  for (const product of productPage.items || []) {
    const available = Number(product.onHand || 0) - Number(product.reserved || 0);
    if (available > Number(product.reorderPoint || 0)) continue;
    const suggested = Math.max(1, Number(product.reorderPoint || 0) * 2 - available);
    const prior = await io.find('Replenishment', { where: { productId: product.id }, limit: 1 });
    const row = (prior.items || [])[0];
    if (row) {
      await io.update('Replenishment', row.id, {
        available,
        reorderPoint: Number(product.reorderPoint || 0),
        suggestedQty: suggested,
        updatedAt: new Date(nowMs).toISOString(),
      });
    } else {
      await io.insert('Replenishment', {
        id: await io.new(),
        productId: product.id,
        sku: product.sku,
        available,
        reorderPoint: Number(product.reorderPoint || 0),
        suggestedQty: suggested,
        status: 'open',
        createdAt: new Date(nowMs).toISOString(),
        updatedAt: new Date(nowMs).toISOString(),
      });
    }
    proposals += 1;
  }

  // 3. Backordered orders: stock may have arrived without a receipt event
  // (a batch edited by hand, a released cancellation). allocate re-checks.
  const shortPage = await io.find('SalesOrder', { where: { status: 'backordered' }, limit: 200 });
  let republished = 0;
  for (const row of shortPage.items || []) {
    await io.queuePublish('allocate', row.id);
    republished += 1;
  }

  return { result: { expired, writtenOff, proposals, republished } };
}
