const REPLAY_LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
];

function replayFold(board, mark) {
  for (const line of REPLAY_LINES) {
    if (board.charAt(line[0]) === mark && board.charAt(line[1]) === mark && board.charAt(line[2]) === mark) {
      return true;
    }
  }
  return false;
}

// The readable half of event sourcing: replay the log and compare it with the
// snapshot. A mismatch is a real bug, not a cache miss.
export async function replay(input, io) {
  const roomId = String(input.roomId || '');
  const room = await io.fetch('Room', roomId);
  if (!room) return { error: 'NotFound' };

  const page = await io.find('Event', { where: { roomId }, order: 'seq asc', limit: 500 });
  const items = page.items || [];

  let board = '.........';
  let moves = 0;
  let winner = null;
  for (const event of items) {
    if (event.kind !== 'move') continue;
    const mark = event.playerId === 'p1' ? 'x' : 'o';
    board = board.slice(0, event.cell) + mark + board.slice(event.cell + 1);
    moves += 1;
    if (replayFold(board, mark)) winner = event.playerId;
  }
  if (!winner && board.indexOf('.') < 0) winner = 'draw';

  if (winner !== room.winner) {
    // The snapshot may be ahead of a stale log; the log wins in a replay.
    winner = winner || null;
  }

  return {
    result: {
      roomId,
      moves,
      board,
      winner,
      consistent: board === room.board && (winner || null) === (room.winner || null),
    },
  };
}
