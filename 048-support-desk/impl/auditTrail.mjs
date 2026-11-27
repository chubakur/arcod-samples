// Who did what inside the tenant. Audit rows are written by the operations,
// not derived from logs, so they survive a container restart.
export async function auditTrail(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const member = await auMember(io, tenantId, actor.id);
  if (!member || !auStaff(member)) return { error: 'Forbidden' };
  const raw = Number(input.limit);
  const limit = Number.isInteger(raw) && raw > 0 ? Math.min(raw, 200) : 50;
  const page = await io.find('Audit', { where: { tenantId }, order: 'at desc', limit });
  return { result: page.items || [] };
}

function auStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function auMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
