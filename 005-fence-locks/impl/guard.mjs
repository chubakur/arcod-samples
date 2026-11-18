// The consumer side of fencing, in one record.
//
// A guarded resource remembers the highest fence it has applied. A write that
// arrives with a lower fence is refused: its holder was paused long enough to
// lose the lease, and its intent is now older than the data.
//
// An equal fence is only a replay: the same payload is a no-op, a different
// payload is refused. Without that rule a previous holder could win a race at
// the very fence it lost, because the number alone cannot tell "my retry" from
// "the other client's late write".
//
// This record is a demo, not a transaction: the read and the write are two
// steps, so two writers can interleave here. A real resource does the compare
// inside its own storage (chubakur/arcod#10).

function fgIso(ms) {
  return new Date(ms).toISOString();
}

function fgView(record) {
  return {
    id: record.id,
    resource: record.resource,
    fence: record.fence,
    value: record.value,
    writer: record.writer,
    writes: record.writes,
    appliedAt: record.appliedAt,
  };
}

export async function guard(input, io) {
  const resource = String(input.resource == null ? '' : input.resource).trim();
  const fence = Number(input.fence);
  const value = String(input.value == null ? '' : input.value);
  const writer = String(input.writer == null ? '' : input.writer).trim();

  if (resource.length < 1 || resource.length > 120) return { error: 'Invalid' };
  if (!Number.isInteger(fence) || fence < 0) return { error: 'Invalid' };
  if (value.length > 4096) return { error: 'Invalid' };
  if (writer.length > 60) return { error: 'Invalid' };

  const now = fgIso(Date.now());
  const current = await io.fetch('Guarded', resource);

  if (!current) {
    const record = {
      id: resource,
      resource,
      fence,
      value,
      writer,
      writes: 1,
      appliedAt: now,
    };
    await io.insert('Guarded', record);
    return { result: fgView(record) };
  }

  if (fence < Number(current.fence)) return { error: 'Conflict' };
  if (fence === Number(current.fence)) {
    if (String(current.value) !== value) return { error: 'Conflict' };
    // A replay of the write we already applied: answer with what is stored.
    return { result: fgView(current) };
  }

  const patch = {
    fence,
    value,
    writer,
    writes: Number(current.writes || 0) + 1,
    appliedAt: now,
  };
  const updated = await io.update('Guarded', resource, patch);
  return { result: fgView(updated || Object.assign({}, current, patch)) };
}
