export async function listExports(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const member = await leMember(io, tenantId, actor.id);
  if (!member || !leStaff(member)) return { error: 'Forbidden' };
  const page = await io.find('Export', { where: { tenantId }, order: 'createdAt desc', limit: 50 });
  return { result: page.items || [] };
}

function leStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function leMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
