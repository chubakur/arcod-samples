export async function getQuote(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const row = await io.fetch('Quote', id);
  if (!row) return { error: 'NotFound' };
  return { result: row };
}
