export async function retry(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const report = await io['fetch']('Report', id);
  if (!report) return { error: 'NotFound' };
  if (report.status === 'queued') return { error: 'Conflict' };

  const updated = await io.update('Report', id, {
    status: 'queued',
    lines: 0,
    words: 0,
    doneAt: null,
  });
  await io.queuePublish('jobs', id);
  return { result: updated };
}
