export async function stats(input, io) {
  const active = await io.count('Subscription', { where: { status: 'active' } });
  const pastDue = await io.count('Subscription', { where: { status: 'past_due' } });
  const paid = await io.find('Invoice', { where: { status: 'paid' }, limit: 1000 });
  const failed = await io.find('Invoice', { where: { status: 'failed' }, limit: 1000 });
  const sum = (rows) => rows.reduce((acc, row) => acc + Number(row.amountCents || 0), 0);
  return {
    result: {
      active: Number(active || 0),
      pastDue: Number(pastDue || 0),
      collectedCents: sum(paid.items || []),
      failedCents: sum(failed.items || []),
    },
  };
}
