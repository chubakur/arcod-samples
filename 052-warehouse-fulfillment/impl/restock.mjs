// Consumer 4: receiving a lot can unblock orders that were waiting for that
// SKU. It re-publishes only those orders; allocate is the single decision
// point about what can actually be reserved.
export async function restock(input, io) {
  const productId = typeof input === 'string' ? input : String((input && input.productId) || '');
  if (!productId) return { result: { scanned: 0, requeued: 0 } };

  const page = await io.find('SalesOrder', { where: { status: 'backordered' }, limit: 200 });
  let requeued = 0;
  for (const order of page.items || []) {
    const lines = await io.find('OrderLine', { where: { orderId: order.id, productId }, limit: 1 });
    if ((lines.items || []).length === 0) continue;
    await io.queuePublish('allocate', order.id);
    requeued += 1;
  }
  return { result: { scanned: (page.items || []).length, requeued } };
}
