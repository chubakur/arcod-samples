// The sidebar: every workspace the caller belongs to, with the role they hold
// there. The membership table is the source, not a token claim.
export async function myTenants(input, io) {
  const actor = await io.actor();
  const page = await io.find('Member', { where: { userId: actor.id }, limit: 200 });
  const out = [];
  for (const member of page.items || []) {
    const tenant = await io.fetch('Tenant', member.tenantId);
    if (!tenant) continue;
    out.push({ tenant, role: member.role });
  }
  return { result: out };
}
