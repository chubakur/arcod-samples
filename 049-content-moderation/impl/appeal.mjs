// One appeal per item, filed by the author. The unique rule on Appeal.itemId is
// the backstop; the status/find check gives the caller a clean 409 first.
export async function appeal(input, io) {
  const actor = await io.actor();
  const itemId = String(input.itemId || '');
  const reason = String(input.reason || '').trim();

  const row = await io.fetch('Item', itemId);
  if (!row) return { error: 'NotFound' };
  if (row.author !== actor.id) return { error: 'Forbidden' };
  if (row.status !== 'rejected') return { error: 'Conflict' };
  if (!reason || reason.length > 1000) return { error: 'Invalid' };

  const existing = await io.find('Appeal', { where: { itemId }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const now = new Date().toISOString();
  const appealRow = {
    id: await io.new(),
    itemId,
    author: actor.id,
    reason,
    status: 'open',
    createdAt: now,
    resolvedAt: null,
    resolvedBy: '',
    escalated: false,
  };
  await io.insert('Appeal', appealRow);
  await io.update('Item', itemId, { status: 'appealed', updatedAt: now });
  await io.insert('Audit', {
    id: await io.new(),
    actor: actor.id,
    action: 'appeal.opened',
    itemId,
    detail: reason,
    at: now,
  });
  await io.queuePublish('notify', itemId);
  return { result: appealRow };
}
