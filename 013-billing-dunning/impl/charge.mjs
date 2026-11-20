// Consumer #1: talk to the gateway. The message key is remembered in kv so a
// redelivered message never charges the card twice.

export async function charge(input, io) {
  const id = String(input.invoiceId || (input.charge && input.charge.invoiceId) || '');
  const attempt = Number(input.attempt || (input.charge && input.charge.attempt) || 1);
  if (!id) return { result: false };

  if (await io.seen('charge:' + id + ':' + attempt)) return { result: true };

  const inv = await io.fetch('Invoice', id);
  if (!inv) return { result: false };
  if (inv.status === 'paid') return { result: true };

  const sub = await io.fetch('Subscription', inv.subscriptionId);
  if (!sub) return { result: false };

  let reply = null;
  try {
    reply = await io.remote('Gateway', 'charge', {
      invoiceId: id,
      amountCents: Number(inv.amountCents),
      cardToken: String(sub.cardToken),
      idempotencyKey: id + ':' + attempt,
    });
  } catch {
    reply = null;
  }

  // io.remote answers with the HTTP envelope { status, body }.
  const body = reply && reply.body ? reply.body : reply;
  const outcome = body && body.status ? String(body.status) : '';

  if (outcome === 'approved') {
    const paidAt = new Date().toISOString();
    const receipt = {
      invoiceId: id,
      subscriptionId: sub.id,
      customer: inv.customer,
      amountCents: Number(inv.amountCents),
      paidAt,
      gatewayRef: body.ref || null,
      attempt,
    };
    const key = 'receipts/' + id + '.json';
    await io.blobPut(key, JSON.stringify(receipt, null, 2), 'application/json');
    await io.update('Invoice', id, {
      status: 'paid',
      attempts: attempt,
      lastError: null,
      gatewayRef: body.ref || null,
      receiptKey: key,
      paidAt,
    });
    const start = new Date();
    const end = new Date(start.getTime() + Number(sub.intervalDays || 30) * 86400000);
    await io.update('Subscription', sub.id, {
      status: 'active',
      attempts: 0,
      periodStart: start.toISOString(),
      periodEnd: end.toISOString(),
    });
    return { result: true };
  }

  const code = body && body.code ? String(body.code) : 'gateway_error';
  await io.update('Invoice', id, { status: 'retrying', attempts: attempt, lastError: code });
  await io.queuePublish('dunning', { invoiceId: id, attempt });
  return { result: true };
}
