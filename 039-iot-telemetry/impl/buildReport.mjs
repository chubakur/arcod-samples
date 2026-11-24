// The CSV is the artifact: devices, readings and the row count are written
// back to the report row so the operator can poll without touching S3.
export async function buildReport(input, io) {
  const id = String(input.reportId || '');
  if (!id) return { result: false };

  const row = await io['fetch']('Report', id);
  if (!row) return { result: false };

  const found = await io.find('Reading', { limit: 5000 });
  const readings = found.items || [];
  const devices = new Set(readings.map((r) => r.deviceId));

  const lines = ['deviceId,metric,value,at'];
  for (const r of readings) {
    lines.push([r.deviceId, r.metric, String(r.value), r.at].join(','));
  }
  const csv = lines.join('\n') + '\n';

  await io.blobPut(row.key, csv);
  await io.update('Report', id, {
    status: 'ready',
    readings: readings.length,
    devices: devices.size,
    doneAt: new Date().toISOString(),
  });
  return { result: true };
}
