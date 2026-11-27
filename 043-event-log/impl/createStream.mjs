// Stream creation is idempotent by name: a retried POST must not fork the log.
// Two first deliveries race on the unique index; the loser re-reads.
export async function createStream(input, io) {
  const name = String(input.name || '').trim().toLowerCase();
  if (!name || name.length > 64) return { error: 'Invalid' };

  const found = await io.find('Stream', { where: { name }, limit: 1 });
  const existing = (found.items || [])[0];
  if (existing) return { result: existing };

  const now = csNowIso();
  const row = {
    id: await io.new(),
    name,
    version: 0,
    eventCount: 0,
    createdAt: now,
    updatedAt: now,
  };
  try {
    await io.insert('Stream', row);
    return { result: row };
  } catch (error) {
    if (!csIsConflict(error)) throw error;
    const again = await io.find('Stream', { where: { name }, limit: 1 });
    const stored = (again.items || [])[0];
    if (stored) return { result: stored };
    return { error: 'Conflict' };
  }
}

function csNowIso() {
  return new Date().toISOString();
}

export function csIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
