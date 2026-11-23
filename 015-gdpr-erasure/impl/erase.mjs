// Consumer one. Three datasets, one message: the unit of progress is the
// request, and the audit row per dataset is both the manifest entry and the
// resume marker. A redelivered message skips a dataset that already has one.
const DATASETS = ['Customer', 'OrderNote', 'SupportTicket'];
const MAX_ROWS = 1000;

export async function erase(input, io) {
  const requestId = String(input.requestId || '');
  if (!requestId) return { result: false };

  const record = await io.fetch('ErasureRequest', requestId);
  if (!record) return { result: false };
  if (record.state === 'erased' || record.state === 'certified') {
    return { result: true, rows: Number(record.rowsDeleted || 0) };
  }

  const startedAt = record.state === 'erasing' && record.attempts > 0 ? record.updatedAt : new Date().toISOString();
  const attempt = Number(record.attempts || 0) + 1;
  await io.update('ErasureRequest', requestId, { state: 'erasing', attempts: attempt, updatedAt: startedAt });

  const done = await io.find('AuditEntry', { where: { requestId, action: 'deleted' }, limit: 100 });
  const already = new Set(((done && done.items) || []).map((row) => String(row.dataset)));

  let deleted = 0;
  for (const dataset of DATASETS) {
    if (already.has(dataset)) continue;

    const found = await io.find(dataset, { where: { subjectHash: record.subjectHash }, limit: MAX_ROWS });
    const rows = (found && found.items) || [];
    for (const row of rows) {
      await io.remove(dataset, row.id);
    }
    deleted += rows.length;
    await io.insert('AuditEntry', {
      id: await io.new(),
      requestId,
      subjectHash: record.subjectHash,
      dataset,
      action: 'deleted',
      rows: rows.length,
      at: new Date().toISOString()
    });
  }

  // The manifest is written after the rows are gone, so a manifest in S3 is
  // evidence of a finished cascade, not of an intended one.
  const entries = await io.find('AuditEntry', { where: { requestId, action: 'deleted' }, limit: 100 });
  const manifest = {
    requestId,
    subjectHash: record.subjectHash,
    generatedAt: new Date().toISOString(),
    datasets: ((entries && entries.items) || []).map((row) => ({ dataset: row.dataset, rows: Number(row.rows || 0) })),
    rowsDeleted: Number(record.rowsDeleted || 0) + deleted
  };
  const key = 'erasure/' + requestId + '/manifest.json';
  await io.blobPut(key, JSON.stringify(manifest, null, 2), 'application/json');

  await io.update('ErasureRequest', requestId, {
    state: 'erased',
    rowsDeleted: manifest.rowsDeleted,
    reportKey: key,
    updatedAt: new Date().toISOString()
  });
  await io.queuePublish('erased', { requestId });
  return { result: true, rows: manifest.rowsDeleted };
}
