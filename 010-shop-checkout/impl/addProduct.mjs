export async function addProduct(input, io) {
  const sku = String(input.sku || '').trim().toLowerCase();
  const title = String(input.title || '').trim();
  const price = Number(input.price);
  const stock = Number(input.stock);

  if (!/^[a-z0-9][a-z0-9-]{1,31}$/.test(sku)) return { error: 'Invalid' };
  if (!title || title.length > 120) return { error: 'Invalid' };
  if (!Number.isInteger(price) || price < 0 || price > 100000000) return { error: 'Invalid' };
  if (!Number.isInteger(stock) || stock < 0 || stock > 1000000) return { error: 'Invalid' };

  const id = await io.new();
  const product = { id, sku, title, price, stock, createdAt: new Date().toISOString() };
  try {
    await io.insert('Product', product);
  } catch (error) {
    // The unique claim on Product.sku is the arbiter: a second insert of the
    // same sku violates it. There is no working find to pre-check (issue #22).
    if (error && (error.error === 'Conflict' || error.name === 'Conflict')) return { error: 'Conflict' };
    throw error;
  }
  return { result: product };
}
