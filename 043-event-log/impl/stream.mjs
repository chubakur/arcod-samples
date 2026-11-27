export async function stream(input, io) {
  const row = await io.fetch('Stream', String(input.streamId || ''));
  if (!row) return { error: 'NotFound' };
  return { result: row };
}
