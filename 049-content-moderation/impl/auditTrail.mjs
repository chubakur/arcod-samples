// Append-only audit rows: who did what to which item, including the automated
// policy decisions and the sweep.
export async function auditTrail(input, io) {
  const actor = await io.actor();
  const me = await auFind(io, actor.id);
  if (!me) return { error: 'Forbidden' };

  const limit = Number(input.limit);
  const page = await io.find('Audit', {
    order: 'at desc',
    limit: Number.isInteger(limit) && limit > 0 ? Math.min(limit, 200) : 50,
  });
  return { result: page.items || [] };
}

async function auFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
