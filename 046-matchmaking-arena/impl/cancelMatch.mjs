async function cancelMatchTicket(io, member, now) {
  const ticket = {
    id: await io.new(),
    playerId: member.playerId,
    mode: '2v2',
    rating: member.ratingBefore,
    status: 'waiting',
    matchId: '',
    createdAt: now,
    updatedAt: now
  };
  await io.insert('QueueTicket', ticket);
  const lock = await io.fetch('QueueLock', member.playerId);
  if (lock) await io.update('QueueLock', member.playerId, { ticketId: ticket.id });
  else {
    await io.insert('QueueLock', {
      id: member.playerId,
      playerId: member.playerId,
      ticketId: ticket.id,
      createdAt: now
    });
  }
  await io.queuePublish('matchmake', ticket.id);
}

export async function cancelMatch(input, io) {
  const id = String(input.id || '');
  const match = await io.fetch('ArenaMatch', id);
  if (!match) return { error: 'NotFound', id };
  if (match.status === 'finished' || match.status === 'cancelled') {
    return { error: 'Conflict', id };
  }

  const page = await io.find('ArenaMember', { where: { matchId: id } });
  const members = page.items || [];
  const now = new Date().toISOString();

  // Cancelling a match that has not started puts everyone back in the queue,
  // otherwise a disconnect would silently remove four players from the pool.
  if (match.status === 'ready') {
    for (const member of members) await cancelMatchTicket(io, member, now);
  }

  const updated = await io.update('ArenaMatch', id, {
    status: 'cancelled',
    winner: '',
    finishedAt: now
  });
  await io.publish('match:' + id, {
    type: 'match',
    event: 'cancelled',
    matchId: id,
    status: 'cancelled',
    reason: String(input.reason || 'cancelled')
  });
  return { result: updated || match };
}
