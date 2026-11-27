// Consumer 3: the only place that talks to the carrier. A failure throws, so
// the queue retries; after the retries the message lands in the dead letter
// and the order stays shipping for an operator to see.
export async function shipOrder(input, io) {
  const orderId = typeof input === 'string' ? input : String((input && input.orderId) || '');
  if (!orderId) return { result: { skipped: true } };

  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { result: { skipped: true } };
  if (order.status !== 'shipping') return { result: { skipped: true, status: order.status } };
  const carrier = String(order.carrier || 'post');

  const prior = await io.find('Shipment', { where: { orderId }, limit: 1 });
  if ((prior.items || []).length > 0) return { result: { skipped: true, tracking: prior.items[0].tracking } };

  const held = await io.find('Reservation', { where: { orderId, status: 'held' }, limit: 200 });
  const units = (held.items || []).reduce((sum, row) => sum + Number(row.qty || 0), 0);

  const payload = JSON.stringify({
    orderId,
    carrier,
    customer: order.customer,
    address: order.address,
    units,
  });
  const reply = await io.remote('Carrier', 'create', { payload });
  const result = reply && reply.body ? reply.body : reply;
  if (!reply || reply.status !== 200 || !result || !result.tracking) {
    const status = reply ? reply.status : 0;
    throw new Error('carrier ' + carrier + ' rejected shipment: HTTP ' + status);
  }

  const now = new Date().toISOString();
  const labelKey = 'labels/' + orderId + '.txt';
  await io.blobPut(labelKey, String(result.label || ''), 'text/plain');

  await io.insert('Shipment', {
    id: await io.new(),
    orderId,
    carrier,
    tracking: String(result.tracking),
    labelKey,
    status: 'created',
    createdAt: now,
  });

  for (const row of held.items || []) {
    await io.update('Reservation', row.id, { status: 'shipped' });
    const product = await io.fetch('Product', row.productId);
    if (product) {
      await io.update('Product', product.id, {
        onHand: Math.max(0, Number(product.onHand || 0) - Number(row.qty || 0)),
        reserved: Math.max(0, Number(product.reserved || 0) - Number(row.qty || 0)),
      });
    }
    await io.insert('Movement', {
      id: await io.new(),
      productId: row.productId,
      batchId: row.batchId,
      kind: 'ship',
      qty: -Number(row.qty || 0),
      ref: String(result.tracking),
      createdAt: now,
    });
  }

  await io.update('SalesOrder', orderId, {
    status: 'shipped',
    tracking: String(result.tracking),
    labelKey,
    updatedAt: now,
  });
  await io.publish('ops', {
    type: 'order',
    event: 'shipped',
    orderId,
    carrier,
    tracking: String(result.tracking),
    units,
  });
  return { result: { orderId, tracking: String(result.tracking), labelKey, units } };
}
