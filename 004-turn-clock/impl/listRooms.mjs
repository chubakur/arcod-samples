export async function listRooms(input, io) {
  const limit = Math.max(1, Math.min(100, Number(input.limit) || 20));
  const page = await io.find('Room', { order: 'createdAt desc', limit });
  return { result: page.items || [] };
}
