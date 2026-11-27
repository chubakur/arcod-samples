// A day report is written to S3 and returned by key, not reshaped in memory:
// the same object can be fetched later or handed to an analyst. The day is
// UTC, matching every stored timestamp.
export async function report(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const day = String(body.day || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return { error: 'Invalid' };
  const start = Date.parse(day + 'T00:00:00Z');
  if (!Number.isFinite(start)) return { error: 'Invalid' };
  const end = start + 24 * 60 * 60 * 1000;
  const from = new Date(start).toISOString();
  const to = new Date(end).toISOString();

  const page = await io.find('Attempt', {
    where: { createdAt: { gte: from, lt: to } },
    order: 'createdAt asc',
    limit: 500,
  });
  const rows = page.items || [];
  const counts = { approved: 0, review: 0, declined: 0, pending: 0 };
  for (const row of rows) {
    if (counts[row.status] == null) counts.pending += 1;
    else counts[row.status] += 1;
  }
  const approvedAmount = await io.aggregate('Attempt', {
    field: 'amount',
    op: 'sum',
    where: { status: 'approved', createdAt: { gte: from, lt: to } },
  });

  const doc = {
    day,
    attempts: rows.length,
    approved: counts.approved,
    review: counts.review,
    declined: counts.declined,
    pending: counts.pending,
    approvedAmount: Number(approvedAmount || 0),
    generatedAt: new Date().toISOString(),
    note: rows.length >= 500 ? 'page capped at 500 rows' : '',
  };
  const content = JSON.stringify(doc, null, 2);
  const key = 'reports/' + day + '.json';
  await io.blobPut(key, content, 'application/json');
  return { result: { key, content, bytes: content.length } };
}
