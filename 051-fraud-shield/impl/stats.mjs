export async function stats(_input, io) {
  const statuses = ['pending', 'approved', 'review', 'declined'];
  const counts = {};
  for (const status of statuses) {
    counts[status] = await io.count('Attempt', { where: { status } });
  }
  const attempts = await io.count('Attempt', { where: {} });
  const avg = await io.aggregate('Attempt', { field: 'score', op: 'avg' });
  const openCases = await io.count('Case', { where: { status: 'open' } });
  return {
    result: {
      attempts,
      pending: counts.pending,
      approved: counts.approved,
      review: counts.review,
      declined: counts.declined,
      avgScore: Number(avg || 0),
      openCases,
    },
  };
}
