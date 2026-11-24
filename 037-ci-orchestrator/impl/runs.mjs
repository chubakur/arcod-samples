export async function runs(input, io) {
  const id = String(input.id || '');
  const pipeline = await io.fetch('Pipeline', id);
  if (!pipeline) return { error: 'NotFound' };
  const page = await io.find('Run', { where: { pipelineId: id }, order: 'queuedAt desc', limit: 100 });
  return { result: page.items || [] };
}
