function enqueueIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}

export async function enqueue(input, io) {
  const playerId = String(input.playerId || '');
  const mode = String(input.mode || '2v2');
  if (mode !== '2v2') return { error: 'Invalid', mode };

  const p = await io.fetch('ArenaPlayer', playerId);
  if (!p) return { error: 'NotFound', playerId };

  const existing = await io.find('QueueTicket', {
    where: { playerId, status: 'waiting' },
    limit: 1
  });
  if ((existing.items || []).length > 0) return { error: 'Conflict', playerId };

  const now = new Date().toISOString();
  const row = {
    id: await io.new(),
    playerId,
    mode,
    rating: p.rating,
    status: 'waiting',
    matchId: '',
    createdAt: now,
    updatedAt: now
  };

  // The unique QueueLock.playerId is the idempotency key. Two interleaved
  // requests both try to insert; the database lets exactly one through.
  try {
    await io.insert('QueueLock', {
      id: playerId,
      playerId,
      ticketId: row.id,
      createdAt: now
    });
  } catch (error) {
    if (enqueueIsConflict(error)) return { error: 'Conflict', playerId };
    throw error;
  }

  try {
    await io.insert('QueueTicket', row);
  } catch (error) {
    await io.remove('QueueLock', playerId);
    throw error;
  }

  await io.queuePublish('matchmake', row.id);
  return { result: row };
}
