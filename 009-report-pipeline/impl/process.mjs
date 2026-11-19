// Queue consumer: the message is the report id.
export async function process(input, io) {
  const id = String(input.reportId || '');
  if (!id) return { result: false };

  let report = null;
  try {
    report = await io['fetch']('Report', id);
  } catch {
    return { result: false };
  }
  if (!report) return { result: false };

  const body = await io.blobGet(id);
  if (body == null) {
    await io.update('Report', id, { status: 'failed', doneAt: new Date().toISOString() });
    return { result: false };
  }

  const text = String(body).replace(/\n$/, '');
  const lines = text.length === 0 ? 0 : text.split(/\r?\n/).length;
  const words = (text.match(/\S+/g) || []).length;

  await io.update('Report', id, {
    status: 'done',
    lines,
    words,
    doneAt: new Date().toISOString(),
  });
  return { result: true };
}
