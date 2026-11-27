// Consumer 3: pack the log into S3 as JSONL.
//
// One object per packed version, written before the row that points at it: a
// crash leaves an orphan object (harmless), never a row with a missing key.
const MAX_EVENTS = 5000;

export async function pack(input, io) {
  const streamId = String(input.streamId || '');
  const head = await io.fetch('Stream', streamId);
  if (!head) return { result: false };

  const page = await io.find('Event', {
    where: { streamId },
    order: 'seq asc',
    limit: MAX_EVENTS,
  });
  const log = page.items || [];

  const lines = log.map((event) =>
    JSON.stringify({
      seq: Number(event.seq),
      type: event.type,
      payload: pkParse(event.payload),
      actor: event.actor,
      recordedAt: event.recordedAt,
    }),
  );
  const body = lines.length ? lines.join('\n') + '\n' : '';
  const version = Number(head.version) || 0;
  const key = 'streams/' + head.name + '/v' + version + '.jsonl';
  await io.blobPut(key, body, 'application/x-ndjson');

  const row = {
    id: head.name + ':v' + version,
    streamId,
    key,
    events: log.length,
    bytes: new TextEncoder().encode(body).length,
    createdAt: new Date().toISOString(),
  };
  try {
    await io.insert('Archive', row);
  } catch (error) {
    // A retried pack rewrites the same object and row.
    if (!pkIsConflict(error)) throw error;
  }
  await io.save('archive:last:' + streamId, {
    b: { key, events: row.events, bytes: row.bytes },
    h: null,
  });
  return { result: true };
}

function pkParse(text) {
  try {
    return JSON.parse(String(text || '{}'));
  } catch {
    return {};
  }
}

function pkIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
