export async function player(input, io) {
  const row = await io.fetch('ArenaPlayer', String(input.id || ''));
  if (!row) return { error: 'NotFound', id: input.id };
  return { result: row };
}
