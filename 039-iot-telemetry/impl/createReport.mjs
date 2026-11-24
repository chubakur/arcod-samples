export async function createReport(input, io) {
  const id = await io.new();
  const report = {
    id,
    key: 'reports/' + id + '.csv',
    status: 'queued',
    readings: 0,
    devices: 0,
    createdAt: new Date().toISOString(),
    doneAt: null,
  };
  await io.insert('Report', report);
  await io.queuePublish('reports', { reportId: id });
  return { result: report };
}
