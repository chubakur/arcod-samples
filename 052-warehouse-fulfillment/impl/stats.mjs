export async function stats(_input, io) {
  const statuses = ['new', 'backordered', 'allocated', 'picking', 'shipping', 'shipped', 'cancelled'];
  const counts = {};
  for (const status of statuses) {
    counts[status] = await io.count('SalesOrder', { where: { status } });
  }
  const products = await io.count('Product', { where: {} });
  const batchesOpen = await io.count('Batch', { where: { status: 'open' } });
  const orders = await io.count('SalesOrder', { where: {} });
  const onHand = await io.aggregate('Product', { field: 'onHand', op: 'sum' });
  const reserved = await io.aggregate('Product', { field: 'reserved', op: 'sum' });
  const openReplenishments = await io.count('Replenishment', { where: { status: 'open' } });
  return {
    result: {
      products,
      batchesOpen,
      orders,
      new: counts.new,
      backordered: counts.backordered,
      allocated: counts.allocated,
      picking: counts.picking,
      shipping: counts.shipping,
      shipped: counts.shipped,
      cancelled: counts.cancelled,
      unitsOnHand: Number(onHand || 0),
      unitsReserved: Number(reserved || 0),
      openReplenishments,
    },
  };
}
