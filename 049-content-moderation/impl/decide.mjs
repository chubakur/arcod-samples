// A decision is final for the queue: the status check rejects a second reviewer
// working from the same stale screen. The notify consumer owns fan-out.
export async function decide(input, io) {
  const actor = await io.actor();
  const me = await dcFind(io, actor.id);
  if (!me) return { error: 'Forbidden' };

  const itemId = String(input.itemId || '');
  const decision = String(input.decision || '');
  const reason = String(input.reason || '').trim();

  const row = await io.fetch('Item', itemId);
  if (!row) return { error: 'NotFound' };
  if (row.status !== 'pending') return { error: 'Conflict' };
  if (decision !== 'approve' && decision !== 'reject') return { error: 'Invalid' };
  if (decision === 'reject' && !reason) return { error: 'Invalid' };
  if (reason.length > 1000) return { error: 'Invalid' };

  const now = new Date().toISOString();
  const status = decision === 'approve' ? 'approved' : 'rejected';
  const decisionRow = {
    id: await io.new(),
    itemId,
    reviewer: actor.id,
    reviewerName: actor.name,
    decision,
    reason,
    createdAt: now,
  };
  await io.insert('Decision', decisionRow);
  await io.update('Item', itemId, {
    status,
    reason,
    decidedBy: actor.id,
    decidedAt: now,
    updatedAt: now,
  });
  await io.insert('Audit', {
    id: await io.new(),
    actor: actor.id,
    action: 'item.' + status,
    itemId,
    detail: reason || 'no reason',
    at: now,
  });
  await io.queuePublish('notify', itemId);
  return { result: { ...row, status, reason, decidedBy: actor.id, decidedAt: now, updatedAt: now } };
}

async function dcFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
