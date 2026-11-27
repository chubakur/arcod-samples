// The checkout call. It validates, stores a pending attempt and publishes the
// id; the vendor call belongs to the consumer. clientRef is the idempotency
// key: a retried request returns the existing attempt and does not enqueue a
// second score.
export async function authorize(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const merchantId = String(body.merchantId || '');
  const cardFingerprint = String(body.cardFingerprint || '').trim();
  const amount = Number(body.amount);
  if (!cardFingerprint) return { error: 'Invalid' };
  if (!Number.isInteger(amount) || amount <= 0) return { error: 'Invalid' };

  const merchant = await io.fetch('Merchant', merchantId);
  if (!merchant) return { error: 'NotFound' };

  const requested = String(body.clientRef || '').trim();
  if (requested) {
    const prior = await io.find('Attempt', { where: { clientRef: requested }, limit: 1 });
    const row = (prior.items || [])[0];
    if (row) return { result: row };
  }

  const attempt = {
    id: await io.new(),
    merchantId,
    clientRef: requested || (await io.new()),
    cardFingerprint,
    customerEmail: String(body.customerEmail || '').trim(),
    amount,
    currency: String(body.currency || 'RUB').trim().toUpperCase(),
    country: String(body.country || 'RU').trim().toUpperCase(),
    status: 'pending',
    score: 0,
    reasons: '',
    ruleHits: 0,
    createdAt: new Date().toISOString(),
    decidedAt: null,
  };
  await io.insert('Attempt', attempt);
  await io.queuePublish('score', attempt.id);
  return { result: attempt };
}
