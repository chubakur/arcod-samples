// The human work queue. Every reviewer sees the same pending rows; the status
// filter also exposes appealed items for the senior screen.
const QUEUE_STATUSES = ['pending', 'appealed', 'approved', 'rejected', 'screening'];

export async function queue(input, io) {
  const actor = await io.actor();
  const me = await quFind(io, actor.id);
  if (!me) return { error: 'Forbidden' };

  const status = String(input.status || 'pending');
  if (QUEUE_STATUSES.indexOf(status) < 0) return { error: 'Invalid' };
  const limit = Number(input.limit);
  const page = await io.find('Item', {
    where: { status },
    order: 'createdAt asc',
    limit: Number.isInteger(limit) && limit > 0 ? Math.min(limit, 200) : 50,
  });
  return { result: page.items || [] };
}

async function quFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
