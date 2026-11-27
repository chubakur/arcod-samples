// A senior reviewer overturns or upholds. Overturning approves the item and
// records the human decision; upholding returns it to rejected, not to the queue.
export async function resolveAppeal(input, io) {
  const actor = await io.actor();
  const me = await raFind(io, actor.id);
  if (!me || (me.role !== 'senior' && me.role !== 'admin')) return { error: 'Forbidden' };

  const appealId = String(input.appealId || '');
  const outcome = String(input.outcome || '');
  const note = String(input.note || '').trim();

  const appealRow = await io.fetch('Appeal', appealId);
  if (!appealRow) return { error: 'NotFound' };
  if (appealRow.status !== 'open') return { error: 'Conflict' };
  if (outcome !== 'uphold' && outcome !== 'overturn') return { error: 'Invalid' };
  if (note.length > 1000) return { error: 'Invalid' };

  const itemRow = await io.fetch('Item', appealRow.itemId);
  if (!itemRow) return { error: 'NotFound' };

  const now = new Date().toISOString();
  const status = outcome === 'overturn' ? 'approved' : 'rejected';
  await io.update('Appeal', appealId, {
    status: outcome === 'overturn' ? 'overturned' : 'upheld',
    resolvedAt: now,
    resolvedBy: actor.id,
  });
  await io.update('Item', appealRow.itemId, {
    status,
    reason: note || ('appeal ' + outcome),
    decidedBy: actor.id,
    decidedAt: now,
    updatedAt: now,
  });
  await io.insert('Audit', {
    id: await io.new(),
    actor: actor.id,
    action: 'appeal.' + outcome,
    itemId: appealRow.itemId,
    detail: note || 'no note',
    at: now,
  });
  await io.queuePublish('notify', appealRow.itemId);
  return {
    result: {
      ...appealRow,
      status: outcome === 'overturn' ? 'overturned' : 'upheld',
      resolvedAt: now,
      resolvedBy: actor.id,
    },
  };
}

async function raFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
