// Operational counters. io.count filters in SQL; only the auto-approved split
// needs the approved rows because decidedBy is a prefix, not an equality.
export async function stats(input, io) {
  const actor = await io.actor();
  const me = await stFind(io, actor.id);
  if (!me) return { error: 'Forbidden' };

  const [total, pending, approved, rejected, appealed, escalated, openAppeals] = await Promise.all([
    io.count('Item', { where: {} }),
    io.count('Item', { where: { status: 'pending' } }),
    io.count('Item', { where: { status: 'approved' } }),
    io.count('Item', { where: { status: 'rejected' } }),
    io.count('Item', { where: { status: 'appealed' } }),
    io.count('Item', { where: { escalated: true } }),
    io.count('Appeal', { where: { status: 'open' } }),
  ]);
  const autoPage = await io.find('Item', { where: { status: 'approved' }, limit: 1000 });
  const autoApproved = (autoPage.items || []).filter((row) => String(row.decidedBy || '').indexOf('policy:') === 0).length;

  return {
    result: {
      total: Number(total) || 0,
      pending: Number(pending) || 0,
      approved: Number(approved) || 0,
      rejected: Number(rejected) || 0,
      appealed: Number(appealed) || 0,
      autoApproved,
      escalated: Number(escalated) || 0,
      openAppeals: Number(openAppeals) || 0,
    },
  };
}

async function stFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
