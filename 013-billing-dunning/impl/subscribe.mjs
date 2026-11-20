// Opening a subscription writes the subscription and its first invoice in
// the same request, then hands the money part to the queue: the HTTP answer
// never waits for the payment gateway.
export async function subscribe(input, io) {
  const planCode = String(input.planCode || '').trim().toLowerCase();
  const customer = String(input.customer || '').trim();
  const email = String(input.email || '').trim();
  const cardToken = String(input.cardToken || '').trim();

  if (!planCode || !customer || !email || !cardToken) return { error: 'Invalid' };
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return { error: 'Invalid' };

  const found = await io.find('Plan', { where: { code: planCode }, limit: 1 });
  const plan = (found.items || [])[0];
  if (!plan || plan.active === false) return { error: 'Invalid' };

  const id = await io.new();
  const now = new Date();
  const end = new Date(now.getTime() + Number(plan.intervalDays) * 86400000);
  const subscription = {
    id,
    planCode: plan.code,
    customer,
    email,
    cardToken,
    status: 'active',
    periodStart: now.toISOString(),
    periodEnd: end.toISOString(),
    intervalDays: Number(plan.intervalDays),
    attempts: 0,
    createdAt: now.toISOString(),
  };
  await io.insert('Subscription', subscription);

  const invoice = {
    id: await io.new(),
    subscriptionId: id,
    customer,
    amountCents: Number(plan.priceCents),
    status: 'pending',
    attempts: 0,
    lastError: null,
    gatewayRef: null,
    receiptKey: null,
    issuedAt: now.toISOString(),
    paidAt: null,
  };
  await io.insert('Invoice', invoice);
  await io.queuePublish('charge', { invoiceId: invoice.id, attempt: 1 });
  return { result: subscription };
}
