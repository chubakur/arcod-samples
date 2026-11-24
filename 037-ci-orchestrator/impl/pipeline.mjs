export async function pipeline(input, io) {
  const id = String(input.id || '');
  const found = await io.fetch('Pipeline', id);
  if (!found) return { error: 'NotFound' };
  const page = await io.find('StepDef', { where: { pipelineId: id }, order: 'position asc', limit: 50 });
  return { result: { pipeline: found, steps: page.items || [] } };
}
