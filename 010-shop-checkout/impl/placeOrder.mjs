export async function placeOrder(input, io) {
  const productId = String(input.product || '');
  const qty = Number(input.qty);
  const token = String(input.token || '');

  if (!productId) return { error: 'Invalid' };
  if (!Number.isInteger(qty) || qty < 1 || qty > 99) return { error: 'Invalid' };
  if (!token || token.length > 64) return { error: 'Invalid' };

  const product = await io['fetch']('Product', productId);
  if (!product) return { error: 'NotFound' };
  if (Number(product.stock) < qty) return { error: 'Conflict' };

  const id = await io.new();
  const amount = Number(product.price) * qty;
  const now = new Date().toISOString();

  let auth = null;
  try {
    const out = await io.remote('Gateway', 'authorize', { order: id, amount, token });
    auth = out && out.body !== undefined ? out.body : out;
  } catch {
    // The gateway said nothing: the order is not created, the caller may retry.
    return { error: 'Unavailable' };
  }
  if (!auth || typeof auth.ref !== 'string' || auth.ref.length === 0) {
    return { error: 'Unavailable' };
  }

  const approved = Boolean(auth.approved);
  const order = {
    id,
    product: productId,
    sku: product.sku,
    qty,
    amount,
    status: approved ? 'paid' : 'rejected',
    paymentRef: auth.ref,
    createdAt: now,
    packedAt: null,
  };
  await io.insert('Order', order);

  if (!approved) return { result: order };

  // Reserve the units. Read-modify-write: two concurrent orders can oversell,
  // there is no compare-and-set in the store contract (issue).
  await io.update('Product', productId, { stock: Number(product.stock) - qty });
  await io.queuePublish('pack', id);
  return { result: order };
}
