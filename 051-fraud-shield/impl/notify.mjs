// Consumer 2: turn a non-approved decision into a review case with a durable
// evidence bundle. The case row is created before the announcement; a
// redelivery finds case by attemptId and does nothing, so the S3 object is
// written once per attempt.
export async function notify(input, io) {
  const attemptId = typeof input === 'string' ? input : String((input && input.attemptId) || '');
  if (!attemptId) return { result: { skipped: true } };

  const attempt = await io.fetch('Attempt', attemptId);
  if (!attempt) return { result: { skipped: true } };
  if (attempt.status === 'approved' || attempt.status === 'pending') {
    return { result: { skipped: true, status: attempt.status } };
  }

  const existing = await io.find('Case', { where: { attemptId }, limit: 1 });
  if ((existing.items || []).length > 0) {
    return { result: { skipped: true, caseId: existing.items[0].id } };
  }

  const decisionPage = await io.find('Decision', { where: { attemptId }, limit: 1 });
  const decision = (decisionPage.items || [])[0] || null;
  const merchant = await io.fetch('Merchant', attempt.merchantId);
  const evidence = {
    attempt,
    decision,
    merchant: merchant || null,
    generatedAt: new Date().toISOString(),
  };
  const key = 'evidence/' + attemptId + '.json';
  const content = JSON.stringify(evidence, null, 2);
  await io.blobPut(key, content, 'application/json');

  const row = {
    id: await io.new(),
    attemptId,
    outcome: attempt.status,
    status: 'open',
    assignee: '',
    notes: '',
    evidenceKey: key,
    openedAt: new Date().toISOString(),
    resolvedAt: null,
  };
  await io.insert('Case', row);
  await io.publish('risk', {
    type: 'case',
    event: 'opened',
    attemptId,
    caseId: row.id,
    outcome: row.outcome,
    amount: attempt.amount,
  });
  return { result: { caseId: row.id, evidenceKey: key } };
}
