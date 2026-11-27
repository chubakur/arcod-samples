// Consumer 1. A queue message only wakes the worker; the waiting tickets in
// SQL are the source of truth, so an extra message can never create a second
// match from the same row.
async function matchmakePause(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function matchmakeIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}

// A row with a fixed id is the lock. Unlike a kv key there is no TTL, so the
// row carries expiresAt and a later worker steals it after a crash.
async function matchmakeGuard(io) {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const now = Date.now();
    try {
      await io.insert('MatchGuard', {
        id: 'matchmake',
        holder: 'worker',
        expiresAt: new Date(now + 30000).toISOString()
      });
      return true;
    } catch (error) {
      if (!matchmakeIsConflict(error)) throw error;
    }
    const current = await io.fetch('MatchGuard', 'matchmake');
    if (current && new Date(current.expiresAt).getTime() <= Date.now()) {
      await io.remove('MatchGuard', 'matchmake');
      continue;
    }
    if (!current) continue;
    await matchmakePause(50);
  }
  return false;
}

async function matchmakeForm(io) {
  const page = await io.find('QueueTicket', {
    where: { status: 'waiting' },
    order: 'createdAt asc',
    limit: 200
  });
  const pool = (page.items || []).filter((t) => t.mode === '2v2');
  if (pool.length < 4) return null;

  // Anchor on the oldest ticket and widen only as far as 400 rating points.
  // A wider window is a policy decision, not a data race: the guard below
  // serialises every pass, so two workers never form overlapping matches.
  const anchor = pool[0];
  const group = [anchor];
  for (const candidate of pool.slice(1)) {
    if (group.length === 4) break;
    if (Math.abs(candidate.rating - anchor.rating) <= 400) group.push(candidate);
  }
  if (group.length < 4) return null;

  const loaded = [];
  for (const t of group) {
    const p = await io.fetch('ArenaPlayer', t.playerId);
    if (p) loaded.push({ ticket: t, player: p });
  }
  if (loaded.length < 4) return null;

  const sorted = loaded.sort((a, b) => a.player.rating - b.player.rating);
  const teamA = [sorted[0], sorted[3]];
  const teamB = [sorted[1], sorted[2]];
  const avg = (team) => Math.round(team.reduce((n, x) => n + x.player.rating, 0) / team.length);
  const now = new Date();
  const match = {
    id: await io.new(),
    mode: '2v2',
    status: 'ready',
    teamA: teamA.map((x) => x.player.id).join(','),
    teamB: teamB.map((x) => x.player.id).join(','),
    ratingA: avg(teamA),
    ratingB: avg(teamB),
    winner: '',
    readyBy: new Date(now.getTime() + 60000).toISOString(),
    archiveKey: '',
    createdAt: now.toISOString(),
    startedAt: '',
    finishedAt: ''
  };
  await io.insert('ArenaMatch', match);

  for (const entry of [...teamA, ...teamB]) {
    const team = teamA.includes(entry) ? 'A' : 'B';
    await io.insert('ArenaMember', {
      id: await io.new(),
      matchId: match.id,
      playerId: entry.player.id,
      name: entry.player.name,
      team,
      ready: false,
      ratingBefore: entry.player.rating,
      ratingAfter: 0,
      delta: 0
    });
    await io.update('QueueTicket', entry.ticket.id, {
      status: 'matched',
      matchId: match.id,
      updatedAt: now.toISOString()
    });
  }

  await io.publish('match:' + match.id, {
    type: 'match',
    event: 'created',
    matchId: match.id,
    status: 'ready',
    readyBy: match.readyBy
  });
  return match.id;
}

export async function matchmake(input, io) {
  const owned = await matchmakeGuard(io);
  if (!owned) throw new Error('matchmaker busy');
  try {
    const id = await matchmakeForm(io);
    return { result: { matchId: id || '' } };
  } finally {
    await io.remove('MatchGuard', 'matchmake');
  }
}
