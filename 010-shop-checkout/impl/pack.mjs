// Queue consumer: the paid order is packed and its invoice is written to S3.
export async function pack(input, io) {
  const id = String(input.orderId || '');
  if (!id) return { result: false };

  let order = null;
  try {
    order = await io['fetch']('Order', id);
  } catch {
    return { result: false };
  }
  if (!order || order.status !== 'paid') return { result: false };

  const at = new Date().toISOString();
  const invoice = {
    id,
    sku: order.sku,
    qty: order.qty,
    amount: order.amount,
    status: 'packed',
    at,
  };
  await io.blobPut(id, JSON.stringify(invoice), 'application/json');
  await io.update('Order', id, { status: 'packed', packedAt: at });
  return { result: true };
}
