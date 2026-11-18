export async function join(input, io) {
  const roomId = String(input.roomId || '');
  const code = String(input.code || '').trim().toUpperCase();
  const name = String(input.name || '').trim();
  if (name.length < 1 || name.length > 60) return { error: 'Invalid' };

  const room = await io.fetch('Room', roomId);
  if (!room) return { error: 'NotFound' };
  if (code !== room.code) return { error: 'Forbidden' };

  // A full or finished room still accepts a spectator: the token identifies a
  // reader, not a seat, and a tick with a spectator token can only sync.
  const taken = !!room.p2 || room.status !== 'waiting';
  const token = await io.new();
  if (taken) {
    await io.insert('Seat', { id: token, roomId, playerId: '', role: 'spectator' });
    return { result: { roomId, playerId: '', token, role: 'spectator', room } };
  }

  const nowMs = Date.now();
  room.p2 = { id: 'p2', name, bankMs: room.bankMs, timeouts: 0, moves: 0 };
  room.status = 'active';
  room.turn = 'p1';
  room.turnStartedAt = new Date(nowMs).toISOString();
  room.deadline = new Date(nowMs + Math.min(room.turnMs, room.p1.bankMs)).toISOString();
  room.seq += 1;

  const event = {
    id: await io.new(),
    roomId,
    seq: room.seq,
    kind: 'start',
    playerId: '',
    cell: -1,
    moveId: '',
    at: new Date(nowMs).toISOString(),
  };

  await io.insert('Seat', { id: token, roomId, playerId: 'p2', role: 'p2' });
  await io.insert('Event', event);
  await io.update('Room', roomId, {
    p2: room.p2,
    status: room.status,
    turn: room.turn,
    seq: room.seq,
    turnStartedAt: room.turnStartedAt,
    deadline: room.deadline,
  });
  await io.publish('room:' + roomId, { type: 'tick', seq: room.seq, kind: 'start', board: room.board, status: room.status, turn: room.turn, timeouts: 0 });

  return { result: { roomId, playerId: 'p2', token, role: 'p2', room } };
}
