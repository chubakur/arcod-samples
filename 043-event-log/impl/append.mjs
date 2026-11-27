// Append is the only writer of history.
//
// expectedVersion is compared with the stream row, then the event is inserted
// first: (streamId, seq) is unique, so two racing appends with the same
// expectedVersion cannot both win — the loser gets a Conflict from the index.
// The stream pointer is moved after the insert; a crash in between leaves the
// log complete and the pointer one behind, which the next append detects as a
// stale version instead of writing a second event with the same seq.
export async function append(input, io) {
  const streamId = String(input.streamId || '');
  const type = String(input.type || '').trim().toLowerCase();
  const payload = String(input.payload ?? '');
  const expected = Number(input.expectedVersion);

  if (!type || type.length > 64) return { error: 'Invalid' };
  if (payload.length > 16384) return { error: 'Invalid' };
  if (!Number.isInteger(expected) || expected < 0) return { error: 'Invalid' };

  const head = await io.fetch('Stream', streamId);
  if (!head) return { error: 'NotFound' };
  if (Number(head.version) !== expected) return { error: 'Conflict' };

  const seq = expected + 1;
  const now = new Date().toISOString();
  const event = {
    id: await io.new(),
    streamId,
    seq,
    type,
    payload,
    actor: String(input.actor || 'api').slice(0, 64),
    recordedAt: now,
  };

  try {
    await io.insert('Event', event);
  } catch (error) {
    if (apIsConflict(error)) return { error: 'Conflict' };
    throw error;
  }

  await io.update('Stream', streamId, { version: seq, eventCount: seq, updatedAt: now });

  // Projection is asynchronous by design: the append is durable whether or not
  // a consumer is up. The publish rides the sql outbox.
  await io.queuePublish('project', event.id);
  return { result: event };
}

function apIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
