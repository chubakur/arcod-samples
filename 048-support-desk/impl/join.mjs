// Joining is idempotent: the membership row is the claim, and a retry with a
// valid code returns the row it already has. A wrong code is a 403, never a
// hint that the tenant exists.
export async function join(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const inviteCode = String(input.inviteCode || '').trim();
  if (!tenantId) return { error: 'NotFound' };

  const tenant = await io.fetch('Tenant', tenantId);
  if (!tenant) return { error: 'NotFound' };
  if (inviteCode !== tenant.inviteCode) return { error: 'Forbidden' };

  const page = await io.find('Member', { where: { tenantId, userId: actor.id }, limit: 1 });
  const mine = (page.items || [])[0];
  if (mine) return { result: mine };

  const now = new Date().toISOString();
  const member = {
    id: await io.new(),
    tenantId,
    userId: actor.id,
    name: actor.name,
    role: 'requester',
    createdAt: now,
  };
  try {
    await io.insert('Member', member);
  } catch (error) {
    if (!jnIsConflict(error)) throw error;
    const again = await io.find('Member', { where: { tenantId, userId: actor.id }, limit: 1 });
    const stored = (again.items || [])[0];
    if (!stored) return { error: 'Conflict' };
    return { result: stored };
  }

  await io.insert('Audit', {
    id: await io.new(),
    tenantId,
    ticketId: '',
    actor: actor.id,
    action: 'member.joined',
    detail: actor.name,
    at: now,
  });
  return { result: member };
}

function jnIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
