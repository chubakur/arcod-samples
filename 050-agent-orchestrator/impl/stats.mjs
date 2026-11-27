export async function stats(_input, io) {
  const statuses = ['queued', 'running', 'succeeded', 'failed', 'budget_exceeded', 'cancelled'];
  const counts = {};
  for (const status of statuses) {
    counts[status] = await io.count('Run', { where: { status } });
  }
  const runs = await io.count('Run', { where: {} });
  const tokens = await io.aggregate('Run', { field: 'tokens', op: 'sum' });
  const toolCalls = await io.aggregate('Run', { field: 'toolCalls', op: 'sum' });
  const amount = await io.aggregate('Usage', { field: 'amount', op: 'sum' });
  return {
    result: {
      runs,
      queued: counts.queued,
      running: counts.running,
      succeeded: counts.succeeded,
      failed: counts.failed,
      budgetExceeded: counts.budget_exceeded,
      cancelled: counts.cancelled,
      tokens: Number(tokens || 0),
      toolCalls: Number(toolCalls || 0),
      amount: Number(amount || 0),
    },
  };
}
