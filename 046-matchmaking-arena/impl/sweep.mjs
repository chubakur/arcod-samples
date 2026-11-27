// Ready-check timeout. The cron hook gets the clock as an argument so the
// behaviour is testable without waiting a real minute.
async function sweepTicket(io, member, now) {
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

export async function sweep(input, io) {
  const now = String(input.now || new Date().toISOString());
  const cutoff = new Date(now).getTime();
  const page = await io.find('ArenaMatch', { where: { status: 'ready' }, limit: 200 });
  const due = (page.items || []).filter((m) => new Date(m.readyBy).getTime() <= cutoff);
  let requeued = 0;

  for (const match of due) {
    const members = (await io.find('ArenaMember', { where: { matchId: match.id } })).items || [];
    for (const member of members) {
      await sweepTicket(io, member, now);
      requeued += 1;
    }
    await io.update('ArenaMatch', match.id, { status: 'cancelled', winner: '', finishedAt: now });
    await io.publish('match:' + match.id, {
      type: 'match',
      event: 'cancelled',
      matchId: match.id,
      status: 'cancelled',
      reason: 'ready-timeout'
    });
  }
  return { result: { expired: due.length, requeued } };
}
