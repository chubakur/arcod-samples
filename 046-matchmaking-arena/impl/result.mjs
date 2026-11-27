// Elo is applied to the team average, then the same delta is mirrored to the
// other team, so the ladder is zero-sum for every match.
function resultIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}

export async function result(input, io) {
  const id = String(input.id || '');
  const winner = String(input.winner || '').toUpperCase();
  if (winner !== 'A' && winner !== 'B') return { error: 'Invalid', winner };

  const match = await io.fetch('ArenaMatch', id);
  if (!match) return { error: 'NotFound', id };
  if (match.status !== 'live') return { error: 'Conflict', id };

  // The unique matchId on MatchOutcome is the settlement lock. Two concurrent
  // result requests both pass the status check; only one insert can win.
  try {
    await io.insert('MatchOutcome', {
      id: await io.new(),
      matchId: id,
      winner,
      createdAt: new Date().toISOString()
    });
  } catch (error) {
    if (resultIsConflict(error)) return { error: 'Conflict', id };
    throw error;
  }

  const page = await io.find('ArenaMember', { where: { matchId: id } });
  const members = page.items || [];
  if (members.length !== 4) return { error: 'Conflict', id };

  const teamA = members.filter((m) => m.team === 'A');
  const teamB = members.filter((m) => m.team === 'B');
  const avgA = teamA.reduce((n, m) => n + m.ratingBefore, 0) / teamA.length;
  const avgB = teamB.reduce((n, m) => n + m.ratingBefore, 0) / teamB.length;
  const expectedA = 1 / (1 + Math.pow(10, (avgB - avgA) / 400));
  const scoreA = winner === 'A' ? 1 : 0;
  const delta = Math.round(32 * (scoreA - expectedA));

  for (const member of members) {
    const change = member.team === 'A' ? delta : -delta;
    const player = await io.fetch('ArenaPlayer', member.playerId);
    if (player) {
      const won = member.team === winner;
      await io.update('ArenaPlayer', player.id, {
        rating: member.ratingBefore + change,
        wins: player.wins + (won ? 1 : 0),
        losses: player.losses + (won ? 0 : 1),
        games: player.games + 1
      });
    }
    await io.update('ArenaMember', member.id, {
      ratingAfter: member.ratingBefore + change,
      delta: change
    });
    await io.remove('QueueLock', member.playerId);
  }

  const finished = await io.update('ArenaMatch', id, {
    status: 'finished',
    winner,
    finishedAt: new Date().toISOString()
  });

  await io.publish('match:' + id, {
    type: 'match',
    event: 'finished',
    matchId: id,
    status: 'finished',
    winner,
    delta
  });
  await io.queuePublish('archive', id);
  return { result: finished || match };
}
