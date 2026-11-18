const FIELD_CLOCK = {
  x: 'xClock',
  y: 'yClock',
  w: 'wClock',
  h: 'hClock',
  color: 'colorClock',
};

const FIELD_BY = {
  x: 'xBy',
  y: 'yBy',
  w: 'wBy',
  h: 'hBy',
  color: 'colorBy',
};

function isInt(value) {
  return typeof value === 'number' && Number.isInteger(value);
}

function provided(input, field) {
  return input[field] !== undefined && input[field] !== null;
}

// Per-field last-writer-wins. Lamport clocks order causal edits; concurrent
// writes to the same field are resolved by client id, so every replica picks
// the same winner. Writes to different fields never overwrite each other.
function wins(clock, by, lamport, clientId) {
  const current = Number(clock) || 0;
  if (lamport > current) return true;
  if (lamport < current) return false;
  return String(clientId) > String(by || '');
}

export async function applyOp(input, io) {
  const roomId = String(input.roomId || '');
  const opId = String(input.opId || '');
  const clientId = String(input.clientId || '').trim();
  const shapeId = String(input.shapeId || '');
  const kind = String(input.kind || '').trim();
  const lamport = Number(input.lamport);

  const room = await io.fetch('Room', roomId);
  if (!room) return { error: 'NotFound' };

  if (!opId || !shapeId) return { error: 'Invalid' };
  if (clientId.length < 1 || clientId.length > 64) return { error: 'Invalid' };
  if (!isInt(lamport) || lamport < 1) return { error: 'Invalid' };
  if (kind !== 'add' && kind !== 'update' && kind !== 'delete') {
    return { error: 'Invalid' };
  }

  // An operation id is the idempotency key: a retry after a lost response
  // returns the stored operation and never applies the patch twice.
  const previous = await io.fetch('Op', opId);
  if (previous) {
    return {
      result: {
        op: previous,
        revision: Number(room.revision) || 0,
        duplicate: true,
      },
    };
  }

  const existing = await io.fetch('Shape', shapeId);
  const patch = {};

  if (kind === 'add') {
    if (existing) return { error: 'Invalid' };
    if (!provided(input, 'x') || !provided(input, 'y')) return { error: 'Invalid' };
    if (!provided(input, 'w') || !provided(input, 'h')) return { error: 'Invalid' };
    if (!provided(input, 'color')) return { error: 'Invalid' };
    if (!isInt(input.x) || !isInt(input.y)) return { error: 'Invalid' };
    if (!isInt(input.w) || !isInt(input.h)) return { error: 'Invalid' };
    if (input.w < 1 || input.h < 1) return { error: 'Invalid' };
    if (input.w > 100000 || input.h > 100000) return { error: 'Invalid' };

    const color = String(input.color).trim();
    if (color.length < 1 || color.length > 32) return { error: 'Invalid' };

    const shape = {
      id: shapeId,
      roomId,
      kind: String(input.kind === 'add' ? 'rect' : kind),
      x: input.x,
      y: input.y,
      w: input.w,
      h: input.h,
      color,
      deleted: false,
      revision: lamport,
      xClock: lamport,
      yClock: lamport,
      wClock: lamport,
      hClock: lamport,
      colorClock: lamport,
      delClock: 0,
      xBy: clientId,
      yBy: clientId,
      wBy: clientId,
      hBy: clientId,
      colorBy: clientId,
      delBy: '',
    };
    await io.insert('Shape', shape);
  } else {
    if (!existing) return { error: 'Invalid' };
    if (existing.deleted) return { error: 'Invalid' };

    if (kind === 'update') {
      for (const field of ['x', 'y', 'w', 'h', 'color']) {
        if (!provided(input, field)) continue;
        const value = field === 'color' ? String(input.color).trim() : input[field];
        if (field === 'color') {
          if (value.length < 1 || value.length > 32) return { error: 'Invalid' };
        } else {
          if (!isInt(value)) return { error: 'Invalid' };
          if ((field === 'w' || field === 'h') && (value < 1 || value > 100000)) {
            return { error: 'Invalid' };
          }
        }
        if (!wins(existing[FIELD_CLOCK[field]], existing[FIELD_BY[field]], lamport, clientId)) {
          continue;
        }
        patch[field] = value;
        patch[FIELD_CLOCK[field]] = lamport;
        patch[FIELD_BY[field]] = clientId;
      }
      if (Object.keys(patch).length === 0) {
        // The patch is older than what the shape already holds. The operation
        // is still recorded: it is the audit trail, not a state mutation.
      } else {
        patch.revision = Math.max(Number(existing.revision) || 0, lamport);
        await io.update('Shape', shapeId, patch);
      }
    } else {
      if (wins(existing.delClock, existing.delBy, lamport, clientId)) {
        await io.update('Shape', shapeId, {
          deleted: true,
          delClock: lamport,
          delBy: clientId,
          revision: Math.max(Number(existing.revision) || 0, lamport),
        });
      }
    }
  }

  const seq = (Number(room.revision) || 0) + 1;
  const op = {
    id: opId,
    roomId,
    seq,
    clientId,
    shapeId,
    kind,
    lamport,
    at: new Date().toISOString(),
  };
  for (const field of ['x', 'y', 'w', 'h', 'color']) {
    if (provided(input, field)) op[field] = input[field];
  }

  await io.insert('Op', op);
  await io.update('Room', roomId, { revision: seq });
  await io.publish('room:' + roomId, { type: 'op', revision: seq, op });

  return { result: { op, revision: seq, duplicate: false } };
}
