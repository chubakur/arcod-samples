// The senior screen: open appeals by default, resolved ones on request.
const APPEAL_STATUSES = ['open', 'upheld', 'overturned'];

export async function appeals(input, io) {
  const actor = await io.actor();
  const me = await apFind(io, actor.id);
  if (!me) return { error: 'Forbidden' };

  const status = String(input.status || 'open');
  if (APPEAL_STATUSES.indexOf(status) < 0) return { error: 'Invalid' };
  const limit = Number(input.limit);
  const page = await io.find('Appeal', {
    where: { status },
    order: 'createdAt asc',
    limit: Number.isInteger(limit) && limit > 0 ? Math.min(limit, 200) : 50,
  });
  return { result: page.items || [] };
}

async function apFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
