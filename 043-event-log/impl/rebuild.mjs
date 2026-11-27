// Consumer 2: drop the view and fold the whole log again.
//
// This is the recovery path when a projection body changes. The log is the
// source of truth; the view is disposable. Rebuild is idempotent because it
// starts from an empty state and replays a deterministic fold.
const RB_MAX_EVENTS = 5000;

export async function rebuild(input, io) {
  const streamId = String(input.streamId || '');
  const head = await io.fetch('Stream', streamId);
  if (!head) return { result: false };

  const page = await io.find('Event', {
    where: { streamId },
    order: 'seq asc',
    limit: RB_MAX_EVENTS,
  });
  const log = page.items || [];

  let state = null;
  for (const event of log) state = rbFold(state, event);

  const existing = await io.fetch('OrderView', streamId);
  if (state && existing) await io.update('OrderView', streamId, state);
  else if (state) await io.insert('OrderView', { id: streamId, ...state });
  else if (existing) await io.remove('OrderView', streamId);

  const last = log[log.length - 1];
  await rbMark(io, streamId, last, log.length);
  return { result: true };
}

function rbFold(view, event) {
  const now = new Date().toISOString();
  const state = {
    id: event.streamId,
    status: view ? view.status : 'new',
    total: view ? Number(view.total) || 0 : 0,
    lines: view ? Number(view.lines) || 0 : 0,
    lastSeq: Number(event.seq),
    updatedAt: now,
  };
  const body = rbParse(event.payload);
  switch (event.type) {
    case 'order.created':
      state.status = 'new';
      state.total = rbInt(body.total);
      state.lines = rbInt(body.lines);
      break;
    case 'order.paid':
      state.status = 'paid';
      if (body.total != null) state.total = rbInt(body.total);
      break;
    case 'order.shipped':
      state.status = 'shipped';
      break;
    case 'order.cancelled':
      state.status = 'cancelled';
      break;
    default:
      break;
  }
  return state;
}

async function rbMark(io, streamId, last, count) {
  const now = new Date().toISOString();
  const id = 'rebuild:' + streamId;
  const row = {
    id,
    name: 'rebuild',
    streamId,
    seq: last ? Number(last.seq) : 0,
    lastEventId: last ? last.id : '',
    updatedAt: now,
  };
  try {
    const existing = await io.fetch('Checkpoint', id);
    if (existing) await io.update('Checkpoint', id, row);
    else await io.insert('Checkpoint', row);
  } catch (error) {
    if (!rbIsConflict(error)) throw error;
  }
  await io.save('rebuild:seq:' + streamId, {
    b: { seq: row.seq, events: count, updatedAt: now },
    h: null,
  });
}

function rbParse(text) {
  try {
    const value = JSON.parse(String(text || '{}'));
    return value && typeof value === 'object' ? value : {};
  } catch {
    return {};
  }
}

function rbInt(value) {
  const n = Number(value);
  return Number.isFinite(n) ? Math.trunc(n) : 0;
}

function rbIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
