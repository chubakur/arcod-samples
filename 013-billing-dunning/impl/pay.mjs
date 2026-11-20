// Manual retry: the operator asks for another attempt on a failed invoice.
// The charge itself still happens on the queue.
export async function pay(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const inv = await io.fetch('Invoice', id);
  if (!inv) return { error: 'NotFound' };
  if (inv.status === 'paid') return { error: 'Conflict' };

  const attempt = Number(inv.attempts || 0) + 1;
  await io.update('Invoice', id, { status: 'pending', lastError: inv.lastError || null });
  await io.queuePublish('charge', { invoiceId: id, attempt });
  return { result: Object.assign({}, inv, { status: 'pending', attempts: attempt }) };
}
