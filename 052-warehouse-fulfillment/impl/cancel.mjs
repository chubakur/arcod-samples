// Cancellation returns every held reservation to its lot. A batch that the
// planner already wrote off is not resurrected: its units are gone.
export async function cancel(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const orderId = String(body.orderId || '');
  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { error: 'NotFound' };
  if (['shipped', 'shipping', 'cancelled'].indexOf(order.status) >= 0) return { error: 'Conflict' };

  const held = await io.find('Reservation', { where: { orderId, status: 'held' }, limit: 200 });
  const now = new Date().toISOString();
  for (const row of held.items || []) {
    const batch = await io.fetch('Batch', row.batchId);
    if (batch && batch.status !== 'expired') {
      const left = Number(batch.remaining || 0) + Number(row.qty || 0);
      await io.update('Batch', batch.id, { remaining: left, status: 'open' });
    }
    const product = await io.fetch('Product', row.productId);
    if (product) {
      const reserved = Math.max(0, Number(product.reserved || 0) - Number(row.qty || 0));
      await io.update('Product', product.id, { reserved });
    }
    await io.update('Reservation', row.id, { status: 'released' });
    await io.insert('Movement', {
      id: await io.new(),
      productId: row.productId,
      batchId: row.batchId,
      kind: 'release',
      qty: Number(row.qty || 0),
      ref: orderId,
      createdAt: now,
    });
  }

  await io.update('SalesOrder', orderId, { status: 'cancelled', updatedAt: now });
  await io.publish('ops', {
    type: 'order',
    event: 'cancelled',
    orderId,
    released: (held.items || []).length,
  });
  return { result: { ...order, status: 'cancelled', updatedAt: now } };
}
