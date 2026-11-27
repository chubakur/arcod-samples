export async function matchInfo(input, io) {
  const id = String(input.id || '');
  const row = await io.fetch('ArenaMatch', id);
  if (!row) return { error: 'NotFound', id };
  const members = await io.find('ArenaMember', { where: { matchId: id }, order: 'team asc' });
  return { result: { match: row, members: members.items || [] } };
}
