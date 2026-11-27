export async function leaderboard(input, io) {
  const raw = Number(input.limit);
  const limit = Number.isInteger(raw) && raw > 0 ? Math.min(raw, 50) : 10;
  const page = await io.find('ArenaPlayer', { order: 'rating desc', limit });
  return { result: page.items || [] };
}
