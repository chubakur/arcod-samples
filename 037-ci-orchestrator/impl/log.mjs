export async function log(input, io) {
  const id = String(input.id || '');
  const position = Number(input.position || 0);
  const found = await io.fetch('Run', id);
  if (!found) return { error: 'NotFound' };

  const page = await io.find('StepRun', { where: { runId: id, position }, limit: 1 });
  const step = ((page && page.items) || [])[0];
  if (!step || !step.logKey) return { error: 'NotFound' };
  const body = await io.blobGet(step.logKey);
  if (body == null) return { error: 'NotFound' };
  return { result: { position: step.position, name: step.name, key: step.logKey, body: String(body) } };
}
