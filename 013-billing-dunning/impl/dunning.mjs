// Consumer #2: decide what a declined charge means. Below the limit it
// re-arms the charge, at the limit it parks the subscription.
const DUNNING_MAX_ATTEMPTS = 3;

export async function dunning(input, io) {
  const id = String(input.invoiceId || (input.dunning && input.dunning.invoiceId) || '');
  const attempt = Number(input.attempt || (input.dunning && input.dunning.attempt) || 1);
  if (!id) return { result: false };

  const inv = await io.fetch('Invoice', id);
  if (!inv) return { result: false };
  if (inv.status === 'paid' || inv.status === 'failed') return { result: true };

  if (attempt < DUNNING_MAX_ATTEMPTS) {
    await io.queuePublish('charge', { invoiceId: id, attempt: attempt + 1 });
    return { result: true };
  }

  await io.update('Invoice', id, { status: 'failed', attempts: attempt });
  const sub = await io.fetch('Subscription', inv.subscriptionId);
  if (sub) {
    await io.update('Subscription', sub.id, { status: 'past_due', attempts: attempt });
  }
  return { result: true };
}
