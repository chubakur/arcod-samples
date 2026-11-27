// Consumer 1: FEFO allocation. Batches are walked in expiry order, so the
// oldest lot leaves first; a lot can serve several orders. A redelivered
// message finds the reservation for (line, batch) and skips it, so remaining
// is never decremented twice.
export async function allocate(input, io) {
  const orderId = typeof input === 'string' ? input : String((input && input.orderId) || '');
  if (!orderId) return { result: { skipped: true } };

  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { result: { skipped: true } };
  if (['allocated', 'picking', 'shipping', 'shipped', 'cancelled'].indexOf(order.status) >= 0) {
    return { result: { skipped: true, status: order.status } };
  }

  const linesPage = await io.find('OrderLine', { where: { orderId }, limit: 100 });
  let allocatedUnits = 0;
  const now = new Date().toISOString();

  for (const line of linesPage.items || []) {
    let need = Number(line.qty || 0) - Number(line.allocated || 0);
    let lineAllocated = Number(line.allocated || 0);
    if (need <= 0) {
      allocatedUnits += lineAllocated;
      continue;
    }
    const lotPage = await io.find('Batch', {
      where: { productId: line.productId, status: 'open' },
      order: 'expiresAt asc',
      limit: 200,
    });
    for (const batch of lotPage.items || []) {
      if (need <= 0) break;
      const remaining = Number(batch.remaining || 0);
      if (remaining <= 0) continue;

      const prior = await io.find('Reservation', {
        where: { lineId: line.id, batchId: batch.id },
        limit: 1,
      });
      if ((prior.items || []).length > 0) continue;

      const take = Math.min(remaining, need);
      await io.insert('Reservation', {
        id: await io.new(),
        orderId,
        lineId: line.id,
        productId: line.productId,
        batchId: batch.id,
        qty: take,
        status: 'held',
        createdAt: now,
      });
      const left = remaining - take;
      await io.update('Batch', batch.id, {
        remaining: left,
        status: left === 0 ? 'depleted' : 'open',
      });
      const product = await io.fetch('Product', line.productId);
      if (product) {
        await io.update('Product', product.id, {
          reserved: Number(product.reserved || 0) + take,
        });
      }
      await io.insert('Movement', {
        id: await io.new(),
        productId: line.productId,
        batchId: batch.id,
        kind: 'reserve',
        qty: -take,
        ref: orderId,
        createdAt: now,
      });
      lineAllocated += take;
      need -= take;
    }
    if (lineAllocated !== Number(line.allocated || 0)) {
      await io.update('OrderLine', line.id, { allocated: lineAllocated });
    }
    allocatedUnits += lineAllocated;
  }

  const total = Number(order.units || 0);
  const full = allocatedUnits >= total && total > 0;
  const status = full ? 'allocated' : 'backordered';
  await io.update('SalesOrder', orderId, {
    status,
    allocatedUnits,
    updatedAt: now,
  });
  await io.publish('ops', {
    type: 'order',
    event: full ? 'allocated' : 'backordered',
    orderId,
    units: total,
    allocated: allocatedUnits,
  });
  if (full) await io.queuePublish('pick', orderId);
  return { result: { orderId, status, allocatedUnits, units: total } };
}
