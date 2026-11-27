// Operational counters for the tenant header. io.count does the filtering in
// SQL; the ticket list is never materialised for a number.
export async function stats(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const member = await stMember(io, tenantId, actor.id);
  if (!member || !stStaff(member)) return { error: 'Forbidden' };

  const [tickets, open, pending, resolved, breached, unassigned, members] = await Promise.all([
    io.count('Ticket', { where: { tenantId } }),
    io.count('Ticket', { where: { tenantId, status: 'open' } }),
    io.count('Ticket', { where: { tenantId, status: 'pending' } }),
    io.count('Ticket', { where: { tenantId, status: 'resolved' } }),
    io.count('Ticket', { where: { tenantId, breachAlerted: true } }),
    io.count('Ticket', { where: { tenantId, status: 'open', assignee: '' } }),
    io.count('Member', { where: { tenantId } }),
  ]);
  return {
    result: {
      tickets: Number(tickets) || 0,
      open: Number(open) || 0,
      pending: Number(pending) || 0,
      resolved: Number(resolved) || 0,
      breached: Number(breached) || 0,
      unassigned: Number(unassigned) || 0,
      members: Number(members) || 0,
    },
  };
}

function stStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function stMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
