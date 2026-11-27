// Escalation is sticky: the flag is written once and a repeated sweep for the
// same (or an earlier) instant changes nothing. Jobs are consumers, not cron
// tasks (#12), so the caller supplies now.
export async function sweep(input, io) {
  const at = input.now ? Date.parse(String(input.now)) : Date.now();
  if (!Number.isFinite(at)) return { result: { escalated: 0, appeals: 0 } };

  const reviewers = await io.find('Reviewer', { limit: 500 });
  const staff = reviewers.items || [];
  let escalated = 0;
  let appeals = 0;
  const now = new Date(at).toISOString();

  const pending = await io.find('Item', { where: { status: 'pending' }, limit: 500 });
  for (const row of pending.items || []) {
    if (row.escalated) continue;
    const due = Date.parse(row.dueAt || '');
    if (!Number.isFinite(due) || due > at) continue;

    escalated += 1;
    await io.update('Item', row.id, { escalated: true, updatedAt: now });
    await io.insert('Audit', {
      id: await io.new(),
      actor: 'system',
      action: 'sla.escalated',
      itemId: row.id,
      detail: 'due ' + row.dueAt,
      at: now,
    });
    for (const person of staff) {
      await swNotify(io, 'sla:' + row.id + ':' + person.userId, person.userId, row.id, 'sla', 'Review overdue: item ' + row.id, now);
    }
  }

  const open = await io.find('Appeal', { where: { status: 'open' }, limit: 500 });
  for (const row of open.items || []) {
    if (row.escalated) continue;
    const created = Date.parse(row.createdAt || '');
    if (!Number.isFinite(created) || created + 72 * 3600 * 1000 > at) continue;

    appeals += 1;
    await io.update('Appeal', row.id, { escalated: true });
    await io.insert('Audit', {
      id: await io.new(),
      actor: 'system',
      action: 'appeal.escalated',
      itemId: row.itemId,
      detail: 'appeal ' + row.id + ' open 72h',
      at: now,
    });
    for (const person of staff) {
      if (person.role !== 'senior' && person.role !== 'admin') continue;
      await swNotify(io, 'appeal-sla:' + row.id + ':' + person.userId, person.userId, row.itemId, 'appeal-sla', 'Appeal overdue: ' + row.id, now);
    }
  }

  return { result: { escalated, appeals } };
}

async function swNotify(io, id, userId, itemId, kind, text, now) {
  try {
    await io.insert('Notification', {
      id,
      userId,
      itemId,
      kind,
      text,
      readAt: null,
      createdAt: now,
    });
  } catch (error) {
    if (!swConflict(error)) throw error;
  }
}

function swConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
