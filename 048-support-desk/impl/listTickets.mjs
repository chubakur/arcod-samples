// Requesters see their own tickets; staff see the tenant queue. The filter is
// applied in the store, not after a full scan, so the limit is meaningful.
export async function listTickets(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const member = await ltMember(io, tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };

  const rawLimit = Number(input.limit);
  const limit = Number.isInteger(rawLimit) && rawLimit > 0 ? Math.min(rawLimit, 100) : 50;
  const status = String(input.status || 'all');
  const where = { tenantId };
  if (!ltStaff(member)) where.requester = actor.id;
  if (status === 'open' || status === 'pending' || status === 'resolved') where.status = status;

  const page = await io.find('Ticket', { where, order: 'updatedAt desc', limit });
  return { result: page.items || [] };
}

function ltStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function ltMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
