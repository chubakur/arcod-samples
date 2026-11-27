// Consumer 1: fold one event into the read model.
//
// Idempotent by seq: the view carries lastSeq, so a redelivered job is a
// no-op. The checkpoint row is the human-visible progress; the kv pointer is
// the O(1) answer for "how far did this stream get" without scanning SQL.
export async function project(input, io) {
  const eventId = String(input.eventId || '');
  const event = await io.fetch('Event', eventId);
  if (!event) return { result: false };

  const view = await io.fetch('OrderView', event.streamId);
  if (view && Number(view.lastSeq) >= Number(event.seq)) {
    await pjMark(io, event, Number(view.lastSeq));
    return { result: true };
  }

  const next = pjFold(view, event);
  try {
    if (view) await io.update('OrderView', view.id, next);
    else await io.insert('OrderView', { id: event.streamId, ...next });
  } catch (error) {
    if (!pjIsConflict(error)) throw error;
    await io.update('OrderView', event.streamId, next);
  }

  await pjMark(io, event, Number(next.lastSeq));
  return { result: true };
}

function pjFold(view, event) {
  const now = new Date().toISOString();
  const state = {
    id: event.streamId,
    status: view ? view.status : 'new',
    total: view ? Number(view.total) || 0 : 0,
    lines: view ? Number(view.lines) || 0 : 0,
    lastSeq: Number(event.seq),
    updatedAt: now,
  };

  const body = pjParse(event.payload);
  switch (event.type) {
    case 'order.created':
      state.status = 'new';
      state.total = pjInt(body.total);
      state.lines = pjInt(body.lines);
      break;
    case 'order.paid':
      state.status = 'paid';
      if (body.total != null) state.total = pjInt(body.total);
      break;
    case 'order.shipped':
      state.status = 'shipped';
      break;
    case 'order.cancelled':
      state.status = 'cancelled';
      break;
    default:
      // Unknown type still advances lastSeq: the log is allowed to grow types
      // that this projection does not read yet.
      break;
  }
  return state;
}

async function pjMark(io, event, seq) {
  const now = new Date().toISOString();
  const id = 'project:' + event.streamId;
  const row = {
    id,
    name: 'project',
    streamId: event.streamId,
    seq,
    lastEventId: event.id,
    updatedAt: now,
  };
  try {
    const existing = await io.fetch('Checkpoint', id);
    if (existing) await io.update('Checkpoint', id, row);
    else await io.insert('Checkpoint', row);
  } catch (error) {
    if (!pjIsConflict(error)) throw error;
  }
  // kv envelope: { b: body, h: hash|null }
  await io.save('project:seq:' + event.streamId, {
    b: { seq, eventId: event.id, updatedAt: now },
    h: null,
  });
}

function pjParse(text) {
  try {
    const value = JSON.parse(String(text || '{}'));
    return value && typeof value === 'object' ? value : {};
  } catch {
    return {};
  }
}

function pjInt(value) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : 0;
}

function pjIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
