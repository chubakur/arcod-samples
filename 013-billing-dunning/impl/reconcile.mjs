// Reconciliation sweep: every invoice stuck in "retrying" (for example a
// consumer died mid-flight) is pushed back onto the queue.
export async function reconcile(input, io) {
  const found = await io.find('Invoice', { where: { status: 'retrying' }, limit: 200 });
  const rows = found.items || [];
  for (const inv of rows) {
    await io.queuePublish('dunning', { invoiceId: inv.id, attempt: Number(inv.attempts || 1) });
  }
  return { result: { ok: true, count: rows.length } };
}
