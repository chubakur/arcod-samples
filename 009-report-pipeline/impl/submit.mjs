export async function submit(input, io) {
  const name = String(input.name || '').trim();
  const body = String(input.body == null ? '' : input.body);

  if (!name || name.length > 120) return { error: 'Invalid' };
  if (body.length < 1 || body.length > 262144) return { error: 'Invalid' };

  const id = await io.new();
  const report = {
    id,
    name,
    status: 'queued',
    size: body.length,
    lines: 0,
    words: 0,
    createdAt: new Date().toISOString(),
    doneAt: null,
  };

  await io.insert('Report', report);
  await io.blobPut(id, body, 'text/plain; charset=utf-8');
  await io.queuePublish('jobs', id);
  return { result: report };
}
