// Assignment is a staff action and the target must already be tenant staff.
// The assignee gets a row in notifications immediately; the audit entry keeps
// who moved the ticket and when.
export async function assign(input, io) {
  const actor = await io.actor();
  const ticketId = String(input.ticketId || '');
  const assignee = String(input.assignee || '');
  const row = await io.fetch('Ticket', ticketId);
  if (!row) return { error: 'NotFound' };

  const mine = await asMember(io, row.tenantId, actor.id);
  if (!mine || !asStaff(mine)) return { error: 'Forbidden' };
  if (row.status === 'resolved') return { error: 'Conflict' };

  const target = await asMember(io, row.tenantId, assignee);
  if (!target || !asStaff(target)) return { error: 'Invalid' };

  const now = new Date().toISOString();
  await io.update('Ticket', ticketId, { assignee, updatedAt: now });
  await io.insert('Audit', {
    id: await io.new(),
    tenantId: row.tenantId,
    ticketId,
    actor: actor.id,
    action: 'ticket.assigned',
    detail: target.name + ' (' + target.userId + ')',
    at: now,
  });
  await io.insert('Notification', {
    id: await io.new(),
    tenantId: row.tenantId,
    ticketId,
    userId: assignee,
    kind: 'assigned',
    text: 'Ticket assigned to you: ' + row.subject,
    readAt: null,
    createdAt: now,
  });
  return { result: { ...row, assignee, updatedAt: now } };
}

function asStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function asMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
