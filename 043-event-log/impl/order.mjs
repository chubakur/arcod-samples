// Reads the projection, never the log: a hot path must not fold history.
export async function order(input, io) {
  const row = await io.fetch('OrderView', String(input.streamId || ''));
  if (!row) return { error: 'NotFound' };
  return { result: row };
}
