export async function runDetail(input, io) {
  const runId = typeof input === 'string' ? input : String((input && input.runId) || '');
  const run = await io.fetch('Run', runId);
  if (!run) return { error: 'NotFound' };
  const page = await io.find('Step', { where: { runId }, order: 'seq asc', limit: 200 });
  return { result: { run, steps: page.items || [] } };
}
