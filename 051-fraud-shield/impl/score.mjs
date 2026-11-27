// Consumer 1: the decision. Every enabled rule is evaluated against the row
// and one vendor call; the verdict is written once and the attempt is updated.
// A vendor failure is fail-closed: review, never approve, because "we could
// not ask" is not evidence of a good payment.
//
// Velocity is an io.count over a datetime window. The current attempt is in
// that window too, so a rule "more than N in W seconds" fires on attempt N+1.
const FRK_FINAL = ['approved', 'review', 'declined'];

function frkNumber(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function frkDayStart(ms) {
  const d = new Date(ms);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())).toISOString();
}

async function frkVendor(io, attempt) {
  const payload = JSON.stringify({
    attemptId: attempt.id,
    merchantId: attempt.merchantId,
    amount: attempt.amount,
    currency: attempt.currency,
    country: attempt.country,
    email: attempt.customerEmail,
    cardFingerprint: attempt.cardFingerprint,
  });
  try {
    const response = await io.remote('RiskService', 'score', { payload });
    const body = response && response.body ? response.body : response;
    if (!response || response.status !== 200 || !body || typeof body.score === 'undefined') {
      return { score: 0, reasons: [], error: 'scoring_unavailable' };
    }
    const reasons = String(body.reasons || '')
      .split(',')
      .map((r) => r.trim())
      .filter((r) => r.length > 0);
    return { score: frkNumber(body.score, 0), reasons, error: '' };
  } catch (error) {
    return { score: 0, reasons: [], error: 'scoring_unavailable' };
  }
}

export async function score(input, io) {
  const attemptId = typeof input === 'string' ? input : String((input && input.attemptId) || '');
  if (!attemptId) return { result: { skipped: true } };

  const attempt = await io.fetch('Attempt', attemptId);
  if (!attempt) return { result: { skipped: true } };
  if (FRK_FINAL.indexOf(attempt.status) >= 0) return { result: { skipped: true, status: attempt.status } };

  const prior = await io.find('Decision', { where: { attemptId }, limit: 1 });
  if ((prior.items || []).length > 0) {
    return { result: { skipped: true, decided: prior.items[0].outcome } };
  }

  const merchant = await io.fetch('Merchant', attempt.merchantId);
  const page = await io.find('Rule', { where: { enabled: true }, limit: 100 });
  const rules = page.items || [];
  const now = Date.now();
  const vendor = await frkVendor(io, attempt);

  const hits = [];
  const reasons = [];
  let evaluated = 0;

  for (const rule of rules) {
    evaluated += 1;
    if (rule.kind === 'blocklist') {
      if (rule.value && rule.value === attempt.cardFingerprint) {
        hits.push({ action: rule.action, reason: 'blocklist:' + rule.name });
      }
      continue;
    }
    if (rule.kind === 'amount_limit') {
      if (attempt.amount > rule.threshold) {
        hits.push({ action: rule.action, reason: 'amount_limit:' + attempt.amount + '>' + rule.threshold });
      }
      continue;
    }
    if (rule.kind === 'velocity') {
      const windowStart = new Date(now - rule.windowSeconds * 1000).toISOString();
      const count = await io.count('Attempt', {
        where: { cardFingerprint: attempt.cardFingerprint, createdAt: { gte: windowStart } },
      });
      if (count > rule.threshold) {
        hits.push({ action: rule.action, reason: 'velocity:' + count + '>' + rule.threshold + '/' + rule.windowSeconds + 's' });
      }
      continue;
    }
    if (rule.kind === 'score') {
      if (!vendor.error && vendor.score >= rule.threshold) {
        hits.push({ action: rule.action, reason: 'score:' + vendor.score + '>=' + rule.threshold });
      }
    }
  }

  // The daily cap is not a Rule row: it belongs to the merchant and the
  // approved total is an aggregate, not a counter that can drift.
  if (merchant && merchant.dailyLimit > 0) {
    const spent = await io.aggregate('Attempt', {
      field: 'amount',
      op: 'sum',
      where: { merchantId: attempt.merchantId, status: 'approved', createdAt: { gte: frkDayStart(now) } },
    });
    if (Number(spent || 0) + attempt.amount > merchant.dailyLimit) {
      hits.push({ action: 'review', reason: 'daily_limit:' + (Number(spent || 0) + attempt.amount) + '>' + merchant.dailyLimit });
    }
  }

  let outcome = 'approved';
  if (hits.some((hit) => hit.action === 'decline')) outcome = 'declined';
  else if (hits.length > 0 || vendor.error) outcome = 'review';

  for (const hit of hits) {
    if (reasons.indexOf(hit.reason) < 0) reasons.push(hit.reason);
  }
  if (vendor.error && reasons.indexOf(vendor.error) < 0) reasons.push(vendor.error);
  if (!vendor.error && vendor.score >= 30) {
    for (const reason of vendor.reasons) {
      if (reasons.indexOf(reason) < 0) reasons.push(reason);
    }
  }
  const decidedAt = new Date().toISOString();
  const decision = {
    id: await io.new(),
    attemptId,
    outcome,
    score: vendor.error ? 0 : vendor.score,
    reasons: reasons.join(','),
    rulesApplied: evaluated,
    decidedAt,
  };
  await io.insert('Decision', decision);
  await io.update('Attempt', attemptId, {
    status: outcome,
    score: decision.score,
    reasons: decision.reasons,
    ruleHits: hits.length,
    decidedAt,
  });
  await io.publish('risk', {
    type: 'decision',
    event: outcome,
    attemptId,
    merchantId: attempt.merchantId,
    score: decision.score,
    reasons: decision.reasons,
    amount: attempt.amount,
  });
  if (outcome !== 'approved') await io.queuePublish('notify', attemptId);
  return { result: { outcome, score: decision.score, reasons: decision.reasons, ruleHits: hits.length } };
}
