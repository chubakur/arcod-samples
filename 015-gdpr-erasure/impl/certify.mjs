// Consumer two. The deletion already happened; this job only buys the legal
// paper. A gateway that is down costs retries and stays visible in the sweep,
// it never resurrects the rows.
export async function certify(input, io) {
  const requestId = String(input.requestId || '');
  if (!requestId) return { result: false };

  const record = await io.fetch('ErasureRequest', requestId);
  if (!record) return { result: false };
  if (record.state === 'certified') return { result: true, certificate: record.certificate };
  if (record.state !== 'erased') return { result: false };

  const reply = await io.remote('Compliance', 'certify', {
    requestId,
    subjectHash: record.subjectHash,
    rowsDeleted: Number(record.rowsDeleted || 0),
    reportKey: record.reportKey
  });
  const body = reply && reply.body ? reply.body : reply;
  const ok = (reply && reply.status === 200) || (body && body.accepted === true);
  if (!ok) throw new Error('compliance gateway rejected the certificate');

  const certificate = String((body && body.certificate) || '');
  const now = new Date().toISOString();
  await io.update('ErasureRequest', requestId, { state: 'certified', certificate, updatedAt: now });
  await io.insert('AuditEntry', {
    id: await io.new(),
    requestId,
    subjectHash: record.subjectHash,
    dataset: 'compliance',
    action: 'certified',
    rows: Number(record.rowsDeleted || 0),
    at: now
  });
  return { result: true, certificate };
}
