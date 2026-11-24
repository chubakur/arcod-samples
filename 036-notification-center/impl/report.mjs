// The export is a CSV in object storage, not a JSON page: the bytes are the
// artifact, the database keeps one row per delivery. The key is derived from
// the campaign, so re-running the export overwrites instead of littering.
export async function report(input, io) {
  const id = String(input.id || '');
  const campaign = await io.fetch('Campaign', id);
  if (!campaign) return { error: 'NotFound' };

  const page = await io.find('Delivery', { where: { campaignId: id }, limit: 500 });
  const rows = page.items || [];
  const header = 'email,name,status,attempts,error,sent_at';
  const lines = rows.map((row) => {
    const sentAt = row.sentAt == null ? '' : new Date(Number(row.sentAt) * 1000).toISOString();
    return [
      String(row.email),
      String(row.name).replace(/,/g, ' '),
      String(row.status),
      String(row.attempts),
      String(row.error || '').replace(/,/g, ' '),
      sentAt,
    ].join(',');
  });
  const key = 'reports/' + id + '.csv';
  await io.blobPut(key, [header].concat(lines).join('\n') + '\n', 'text/csv');
  const sent = rows.filter((row) => row.status === 'sent').length;
  const failed = rows.filter((row) => row.status === 'failed').length;
  return { result: { key, rows: rows.length, sent, failed } };
}
