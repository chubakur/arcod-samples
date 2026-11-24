export async function report(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const row = await io['fetch']('Report', id);
  if (!row) return { error: 'NotFound' };
  return { result: row };
}
