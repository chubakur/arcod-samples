// Staff rights are tenant-local. Only an owner can grant them, and the owner
// role itself is never handed out through this path.
export async function promote(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const userId = String(input.userId || '');
  const role = String(input.role || '').trim();
  if (!tenantId) return { error: 'NotFound' };
  if (role !== 'agent' && role !== 'requester') return { error: 'Invalid' };

  const mine = await prMember(io, tenantId, actor.id);
  if (!mine || mine.role !== 'owner') return { error: 'Forbidden' };

  const target = await prMember(io, tenantId, userId);
  if (!target) return { error: 'NotFound' };
  if (target.role === 'owner') return { error: 'Forbidden' };

  await io.update('Member', target.id, { role });
  await io.insert('Audit', {
    id: await io.new(),
    tenantId,
    ticketId: '',
    actor: actor.id,
    action: 'member.role',
    detail: userId + ' -> ' + role,
    at: new Date().toISOString(),
  });
  return { result: { ...target, role } };
}

async function prMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
