export async function listRooms(input, io) {
  const limit = Math.max(1, Math.min(200, Number(input.limit) || 50));
  const page = await io.find('Room', { order: 'createdAt desc', limit });
  return { result: page.items || [] };
}
