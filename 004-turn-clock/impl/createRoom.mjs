export async function createRoom(input, io) {
  const name = String(input.name || '').trim();
  const player = String(input.player || '').trim();
  const turnSeconds = Number(input.turnSeconds);
  const bankSeconds = Number(input.bankSeconds);

  if (name.length < 1 || name.length > 80) return { error: 'Invalid' };
  if (player.length < 1 || player.length > 60) return { error: 'Invalid' };
  if (!Number.isInteger(turnSeconds) || turnSeconds < 2 || turnSeconds > 600) return { error: 'Invalid' };
  if (!Number.isInteger(bankSeconds) || bankSeconds < turnSeconds || bankSeconds > 7200) return { error: 'Invalid' };

  const id = await io.new();
  const token = await io.new();
  // The code is derived from the room id, so two rooms cannot collide by luck.
  const code = id.replace(/-/g, '').slice(0, 6).toUpperCase();

  const room = {
    id,
    code,
    name,
    status: 'waiting',
    board: '.........',
    p1: { id: 'p1', name: player, bankMs: bankSeconds * 1000, timeouts: 0, moves: 0 },
    p2: null,
    turn: '',
    seq: 0,
    turnMs: turnSeconds * 1000,
    bankMs: bankSeconds * 1000,
    createdAt: new Date().toISOString(),
    turnStartedAt: null,
    deadline: null,
    winner: null,
    reason: null,
  };

  await io.insert('Room', room);
  await io.insert('Seat', { id: token, roomId: id, playerId: 'p1', role: 'p1' });

  return { result: { roomId: id, playerId: 'p1', token, role: 'p1', room } };
}
