// Hand the order to the carrier consumer. The request does not wait for the
// external call; 200 means "accepted for shipping". Only a picking order can
// be shipped, and only once: the second call sees shipping and conflicts.
export async function ship(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const orderId = String(body.orderId || '');
  const carrier = String(body.carrier || 'post').trim().toLowerCase();

  const order = await io.fetch('SalesOrder', orderId);
  if (!order) return { error: 'NotFound' };
  if (order.status !== 'picking') return { error: 'Conflict' };

  const updated = {
    ...order,
    status: 'shipping',
    carrier,
    updatedAt: new Date().toISOString(),
  };
  await io.update('SalesOrder', orderId, {
    status: 'shipping',
    carrier,
    updatedAt: updated.updatedAt,
  });
  await io.queuePublish('ship', orderId);
  return { result: updated };
}
