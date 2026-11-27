export async function ready(input, io) {
  const id = String(input.id || '');
  const playerId = String(input.playerId || '');
  const match = await io.fetch('ArenaMatch', id);
  if (!match) return { error: 'NotFound', id };
  if (match.status !== 'ready') return { error: 'Conflict', id };

  const page = await io.find('ArenaMember', { where: { matchId: id } });
  const members = page.items || [];
  const me = members.find((m) => m.playerId === playerId);
  if (!me) return { error: 'NotFound', id };

  if (!me.ready) await io.update('ArenaMember', me.id, { ready: true });
  const nowReady = members.map((m) => (m.playerId === playerId ? { ...m, ready: true } : m));
  const readyCount = nowReady.filter((m) => m.ready).length;

  let updated = match;
  if (readyCount === members.length && members.length === 4) {
    updated = await io.update('ArenaMatch', id, {
      status: 'live',
      startedAt: new Date().toISOString()
    });
    await io.publish('match:' + id, {
      type: 'match',
      event: 'live',
      matchId: id,
      status: 'live'
    });
  } else {
    await io.publish('match:' + id, {
      type: 'match',
      event: 'ready',
      matchId: id,
      status: 'ready',
      ready: readyCount,
      players: members.length
    });
  }
  return { result: updated || match };
}
