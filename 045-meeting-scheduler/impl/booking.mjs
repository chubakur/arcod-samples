export async function booking(input, io) {
  const row = await io.fetch('Booking', String(input.id || ''));
  if (!row) return { error: 'NotFound' };
  return { result: row };
}
