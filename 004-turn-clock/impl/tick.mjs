// One tick = settle expired clocks, apply the request, hand back the delta.
// Everything is idempotent per (room, moveId): a resent move never moves twice.

const TICK_LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
];

const tickIso = (ms) => new Date(ms).toISOString();
const tickStamp = (value) => (value ? Date.parse(value) : 0);

function tickPlayerOf(room, id) {
  if (room.p1 && room.p1.id === id) return room.p1;
  if (room.p2 && room.p2.id === id) return room.p2;
  return null;
}

function tickOpponentOf(room, id) {
  if (id === 'p1') return room.p2 || null;
  return room.p1 || null;
}

function tickFold(board, mark) {
  for (const line of TICK_LINES) {
    if (board.charAt(line[0]) === mark && board.charAt(line[1]) === mark && board.charAt(line[2]) === mark) {
      return true;
    }
  }
  return false;
}

// A clock that ran out is a fact, not an event: it is materialised at the moment
// the deadline passed, so the log is the same whether a client polls or not.
async function tickSettle(room, io, nowMs) {
  const events = [];
  let guard = 0;
  while (room.status === 'active' && room.deadline && nowMs >= tickStamp(room.deadline) && guard < 32) {
    guard += 1;
    const seat = tickPlayerOf(room, room.turn);
    if (!seat) break;
    const granted = Math.min(room.turnMs, Math.max(0, seat.bankMs));
    seat.bankMs = Math.max(0, seat.bankMs - granted);
    seat.timeouts += 1;
    room.seq += 1;
    const moment = room.deadline;
    const event = {
      id: await io.new(),
      roomId: room.id,
      seq: room.seq,
      kind: 'timeout',
      playerId: seat.id,
      cell: -1,
      moveId: '',
      at: moment,
    };
    await io.insert('Event', event);
    events.push(event);

    const other = tickOpponentOf(room, seat.id);
    if (!other || seat.bankMs <= 0) {
      room.status = 'finished';
      room.winner = other ? other.id : '';
      room.reason = 'timeout';
      room.turn = '';
      room.turnStartedAt = null;
      room.deadline = null;
    } else {
      room.turn = other.id;
      room.turnStartedAt = moment;
      room.deadline = tickIso(tickStamp(moment) + Math.min(room.turnMs, Math.max(0, other.bankMs)));
    }
  }
  return events;
}

// Arcod's kv has no compare-and-set yet (arcod issue #10), so two ticks for the
// same room are serialised inside this process before they touch the snapshot.
// A second instance would need CAS: the lock is a property of the deployment,
// not of the model.
const TICK_LOCKS = new Map();

function tickLock(key) {
  const previous = TICK_LOCKS.get(key) || Promise.resolve();
  let release = () => {};
  const mine = new Promise((resolve) => { release = resolve; });
  const tail = previous.then(() => mine);
  TICK_LOCKS.set(key, tail);
  tail.then(() => {
    if (TICK_LOCKS.get(key) === tail) TICK_LOCKS.delete(key);
  });
  return previous.then(() => release);
}

export async function tick(input, io) {
  const roomId = String(input.roomId || '');
  const release = await tickLock(roomId);
  try {
    return await tickLocked(input, io);
  } finally {
    release();
  }
}

async function tickLocked(input, io) {
  const roomId = String(input.roomId || '');
  const kind = String(input.kind || 'sync');
  const token = String(input.token || '');
  const moveId = String(input.moveId || '');
  const cell = Number(input.cell);
  const since = Math.max(0, Number(input.sinceSeq) || 0);

  if (['sync', 'move', 'resign'].indexOf(kind) < 0) return { error: 'Invalid' };

  const room = await io.fetch('Room', roomId);
  if (!room) return { error: 'NotFound' };

  const seat = token ? await io.fetch('Seat', token) : null;
  if (token && (!seat || seat.roomId !== roomId)) return { error: 'Forbidden' };
  const me = seat ? tickPlayerOf(room, seat.playerId) : null;

  const nowMs = Date.now();
  const timeouts = await tickSettle(room, io, nowMs);
  const appended = timeouts.slice();
  let accepted = false;
  let duplicate = false;
  let note = '';

  if (kind === 'sync') {
    accepted = true;
  } else if (kind === 'move') {
    if (!me) return { error: 'Forbidden' };
    if (moveId) {
      const seen = await io.find('Event', { where: { roomId, moveId }, limit: 1 });
      if ((seen.items || []).length > 0) {
        duplicate = true;
        accepted = true;
      }
    }
    if (!duplicate) {
      if (room.status !== 'active') {
        note = room.status === 'finished' ? 'finished' : 'waiting';
      } else if (room.turn !== me.id) {
        note = 'out-of-turn';
      } else if (!Number.isInteger(cell) || cell < 0 || cell > 8) {
        note = 'bad-cell';
      } else if (room.board.charAt(cell) !== '.') {
        note = 'cell-taken';
      } else {
        const mark = me.id === 'p1' ? 'x' : 'o';
        room.board = room.board.slice(0, cell) + mark + room.board.slice(cell + 1);
        // The bank pays for the think time, not for the move itself.
        me.bankMs = Math.max(0, me.bankMs - Math.max(0, nowMs - tickStamp(room.turnStartedAt)));
        me.moves += 1;
        room.seq += 1;
        const event = {
          id: await io.new(),
          roomId,
          seq: room.seq,
          kind: 'move',
          playerId: me.id,
          cell,
          moveId,
          at: tickIso(nowMs),
        };
        await io.insert('Event', event);
        appended.push(event);

        const other = tickOpponentOf(room, me.id);
        if (tickFold(room.board, mark)) {
          room.status = 'finished';
          room.winner = me.id;
          room.reason = 'line';
          room.turn = '';
          room.turnStartedAt = null;
          room.deadline = null;
        } else if (room.board.indexOf('.') < 0) {
          room.status = 'finished';
          room.winner = 'draw';
          room.reason = 'draw';
          room.turn = '';
          room.turnStartedAt = null;
          room.deadline = null;
        } else {
          room.turn = other.id;
          room.turnStartedAt = tickIso(nowMs);
          room.deadline = tickIso(nowMs + Math.min(room.turnMs, Math.max(0, other.bankMs)));
        }
        accepted = true;
      }
    }
  } else {
    if (!me) return { error: 'Forbidden' };
    if (room.status !== 'active') {
      note = 'finished';
    } else {
      const other = tickOpponentOf(room, me.id);
      room.seq += 1;
      const event = {
        id: await io.new(),
        roomId,
        seq: room.seq,
        kind: 'resign',
        playerId: me.id,
        cell: -1,
        moveId: '',
        at: tickIso(nowMs),
      };
      await io.insert('Event', event);
      appended.push(event);
      room.status = 'finished';
      room.winner = other ? other.id : '';
      room.reason = 'resign';
      room.turn = '';
      room.turnStartedAt = null;
      room.deadline = null;
      accepted = true;
    }
  }

  await io.update('Room', room.id, {
    status: room.status,
    board: room.board,
    p1: room.p1,
    p2: room.p2,
    turn: room.turn,
    seq: room.seq,
    turnStartedAt: room.turnStartedAt,
    deadline: room.deadline,
    winner: room.winner,
    reason: room.reason,
  });

  if (appended.length > 0) {
    await io.publish('room:' + room.id, {
      type: 'tick',
      seq: room.seq,
      kind: appended[appended.length - 1].kind,
      board: room.board,
      status: room.status,
      turn: room.turn,
      timeouts: timeouts.length,
    });
  }

  const page = await io.find('Event', {
    where: { roomId, seq: { gt: since } },
    order: 'seq asc',
    limit: 200,
  });

  return {
    result: {
      seq: room.seq,
      accepted,
      duplicate,
      timeouts: timeouts.length,
      note,
      room,
      events: page.items || [],
      serverTime: tickIso(nowMs),
    },
  };
}
