export async function createRoom(input, io) {
  const name = String(input.name || '').trim();
  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };

  const room = {
    id: await io.new(),
    name,
    createdAt: new Date().toISOString(),
    revision: 0,
  };
  await io.insert('Room', room);
  return { result: room };
}
