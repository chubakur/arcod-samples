export async function getOrder(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const order = await io['fetch']('Order', id);
  if (!order) return { error: 'NotFound' };
  return { result: order };
}
