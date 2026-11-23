export async function show(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const record = await io.fetch('ErasureRequest', id);
  if (!record) return { error: 'NotFound' };

  const found = await io.find('AuditEntry', { where: { requestId: id }, limit: 200 });
  const manifest = ((found && found.items) || []).sort((a, b) => String(a.at).localeCompare(String(b.at)));

  // Residue is counted live: a status endpoint that reported the consumer's
  // own bookkeeping would be a rumour, not evidence.
  const datasets = ['Customer', 'OrderNote', 'SupportTicket'];
  const remaining = [];
  for (const dataset of datasets) {
    const count = await io.count(dataset, { where: { subjectHash: record.subjectHash } });
    remaining.push({ dataset, rows: Number(count || 0) });
  }
  return { result: { request: record, manifest, remaining } };
}
