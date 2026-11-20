// Renewal sweep: this is what a scheduler would call once a day. Every
// active subscription whose period has ended gets a fresh invoice.
export async function renew(input, io) {
  const found = await io.find('Subscription', { where: { status: 'active' }, limit: 200 });
  const now = Date.now();
  let count = 0;
  for (const sub of found.items || []) {
    const end = Date.parse(String(sub.periodEnd || ''));
    if (!Number.isFinite(end) || end > now) continue;
    const start = new Date(now);
    const next = new Date(start.getTime() + Number(sub.intervalDays || 30) * 86400000);
    await io.update('Subscription', sub.id, {
      periodStart: start.toISOString(),
      periodEnd: next.toISOString(),
      attempts: 0,
    });
    const invoice = {
      id: await io.new(),
      subscriptionId: sub.id,
      customer: sub.customer,
      amountCents: 0,
      status: 'pending',
      attempts: 0,
      lastError: null,
      gatewayRef: null,
      receiptKey: null,
      issuedAt: start.toISOString(),
      paidAt: null,
    };
    const plan = await io.find('Plan', { where: { code: sub.planCode }, limit: 1 });
    const row = (plan.items || [])[0];
    invoice.amountCents = row ? Number(row.priceCents) : 0;
    await io.insert('Invoice', invoice);
    await io.queuePublish('charge', { invoiceId: invoice.id, attempt: 1 });
    count += 1;
  }
  return { result: { ok: true, count } };
}
