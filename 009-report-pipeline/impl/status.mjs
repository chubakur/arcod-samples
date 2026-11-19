export async function status(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const report = await io['fetch']('Report', id);
  if (!report) return { error: 'NotFound' };
  return { result: report };
}
