// The .ics lives in S3, not in the row. The row only carries the key, so the
// same object can be re-fetched, re-sent or audited without a database read of
// the payload.
export async function invite(input, io) {
  const id = String(input.id || '');
  const rows = await io.find('Invite', { where: { bookingId: id, kind: 'invite' }, limit: 1 });
  const row = (rows.items || [])[0];
  if (!row) return { error: 'NotFound' };

  const body = row.icsKey ? await io.blobGet(row.icsKey) : null;
  return {
    result: {
      key: row.icsKey || '',
      kind: row.kind,
      status: row.status,
      body: body || ''
    }
  };
}
