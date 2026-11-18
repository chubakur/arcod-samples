export async function getRoom(input, io) {
  const room = await io.fetch('Room', String(input.id || ''));
  if (!room) return { error: 'NotFound' };
  return { result: room };
}
