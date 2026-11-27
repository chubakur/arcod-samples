// Resolving twice is a conflict, not a silent success: the second caller is
// working from a stale screen. The requester gets one notification row.
export async function resolve(input, io) {
  const actor = await io.actor();
  const ticketId = String(input.ticketId || '');
  const row = await io.fetch('Ticket', ticketId);
  if (!row) return { error: 'NotFound' };

  const mine = await rsMember(io, row.tenantId, actor.id);
  if (!mine || !rsStaff(mine)) return { error: 'Forbidden' };
  if (row.status === 'resolved') return { error: 'Conflict' };

  const now = new Date().toISOString();
  await io.update('Ticket', ticketId, { status: 'resolved', resolvedAt: now, updatedAt: now });
  await io.insert('Audit', {
    id: await io.new(),
    tenantId: row.tenantId,
    ticketId,
    actor: actor.id,
    action: 'ticket.resolved',
    detail: row.subject,
    at: now,
  });
  await io.insert('Notification', {
    id: await io.new(),
    tenantId: row.tenantId,
    ticketId,
    userId: row.requester,
    kind: 'resolved',
    text: 'Ticket resolved: ' + row.subject,
    readAt: null,
    createdAt: now,
  });
  return { result: { ...row, status: 'resolved', resolvedAt: now, updatedAt: now } };
}

function rsStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function rsMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
