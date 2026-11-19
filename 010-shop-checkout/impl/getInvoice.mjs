export async function getInvoice(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const order = await io['fetch']('Order', id);
  if (!order) return { error: 'NotFound' };
  if (order.status !== 'packed') return { error: 'Conflict' };
  const raw = await io.blobGet(id);
  if (raw == null) return { error: 'Conflict' };
  try {
    return { result: JSON.parse(String(raw)) };
  } catch {
    return { error: 'Conflict' };
  }
}
