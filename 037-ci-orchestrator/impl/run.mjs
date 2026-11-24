export async function run(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Run', id);
  if (!found) return { error: 'NotFound' };
  const page = await io.find('StepRun', { where: { runId: id }, order: 'position asc', limit: 50 });
  return { result: { run: found, steps: page.items || [] } };
}
