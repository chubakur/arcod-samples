export async function createPlayer(input, io) {
  const name = String(input.name || '').trim();
  const raw = Number(input.rating);
  const rating = Number.isFinite(raw) && raw >= 0 ? Math.round(raw) : 1200;
  if (!name || name.length > 80 || rating > 4000) return { error: 'Invalid', name };
  const row = {
    id: await io.new(),
    name,
    rating,
    wins: 0,
    losses: 0,
    games: 0,
    createdAt: new Date().toISOString()
  };
  await io.insert('ArenaPlayer', row);
  return { result: row };
}
