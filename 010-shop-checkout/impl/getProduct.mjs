export async function getProduct(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const product = await io['fetch']('Product', id);
  if (!product) return { error: 'NotFound' };
  return { result: product };
}
