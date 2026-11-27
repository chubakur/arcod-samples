// Creating a workspace makes the caller its owner in one transaction-shaped
// sequence: the tenant row and the owner membership are written together.
// A duplicate slug is a 409, not a second workspace behind the same name.
export async function createTenant(input, io) {
  const actor = await io.actor();
  const name = String(input.name || '').trim();
  const slug = String(input.slug || '').trim().toLowerCase();
  const inviteCode = String(input.inviteCode || '').trim();

  if (!name || name.length > 80) return { error: 'Invalid' };
  if (!/^[a-z0-9][a-z0-9-]{2,31}$/.test(slug)) return { error: 'Invalid' };
  if (!/^[A-Za-z0-9]{6,32}$/.test(inviteCode)) return { error: 'Invalid' };

  const existing = await io.find('Tenant', { where: { slug }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const now = new Date().toISOString();
  const tenant = {
    id: await io.new(),
    slug,
    name,
    inviteCode,
    openLimit: 20,
    createdAt: now,
  };

  try {
    await io.insert('Tenant', tenant);
  } catch (error) {
    if (ctIsConflict(error)) return { error: 'Conflict' };
    throw error;
  }

  await io.insert('Member', {
    id: await io.new(),
    tenantId: tenant.id,
    userId: actor.id,
    name: actor.name,
    role: 'owner',
    createdAt: now,
  });
  await io.insert('Audit', {
    id: await io.new(),
    tenantId: tenant.id,
    ticketId: '',
    actor: actor.id,
    action: 'tenant.created',
    detail: slug,
    at: now,
  });

  return { result: { tenant, role: 'owner' } };
}

function ctIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
