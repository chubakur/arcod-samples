// Checkout. Lines are merged by SKU so a duplicate line cannot reserve the same
// units twice. Stock is not consulted here at all: allocation is a consumer,
// and an order that cannot be filled becomes backordered rather than rejected.
export async function createOrder(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const clientRef = String(body.clientRef || '').trim();
  const customer = String(body.customer || '').trim();
  const address = String(body.address || '').trim();
  const lines = Array.isArray(body.lines) ? body.lines : [];
  if (!customer || !address) return { error: 'Invalid' };
  if (lines.length === 0 || lines.length > 50) return { error: 'Invalid' };

  if (clientRef) {
    const prior = await io.find('SalesOrder', { where: { clientRef }, limit: 1 });
    if ((prior.items || []).length > 0) return { result: prior.items[0] };
  }

  const merged = new Map();
  for (const line of lines) {
    const sku = String((line && line.sku) || '').trim().toLowerCase();
    const qty = Number(line && line.qty);
    if (!sku || !Number.isInteger(qty) || qty <= 0) return { error: 'Invalid' };
    merged.set(sku, (merged.get(sku) || 0) + qty);
  }

  const resolved = [];
  let units = 0;
  for (const [sku, qty] of merged) {
    const found = await io.find('Product', { where: { sku }, limit: 1 });
    const product = (found.items || [])[0];
    if (!product) return { error: 'NotFound' };
    resolved.push({ product, qty });
    units += qty;
  }

  const now = new Date().toISOString();
  const order = {
    id: await io.new(),
    clientRef: clientRef || (await io.new()),
    customer,
    address,
    status: 'new',
    units,
    allocatedUnits: 0,
    carrier: '',
    tracking: '',
    labelKey: '',
    createdAt: now,
    updatedAt: now,
  };
  await io.insert('SalesOrder', order);
  for (const item of resolved) {
    await io.insert('OrderLine', {
      id: await io.new(),
      orderId: order.id,
      productId: item.product.id,
      sku: item.product.sku,
      qty: item.qty,
      allocated: 0,
    });
  }
  await io.queuePublish('allocate', order.id);
  return { result: order };
}
