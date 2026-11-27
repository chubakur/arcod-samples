// The log is the source of truth. Arcod's sql update has no compare-and-set,
// so two parallel writers must not both read-modify-write Doc.content. Instead
// each request appends one immutable row and answers with a replay.
function applyOpText(content, kind, pos, text) {
  const body = String(content || '');
  const at = Math.min(Math.max(Number(pos) || 0, 0), body.length);
  if (kind === 'insert') return body.slice(0, at) + text + body.slice(at);
  const count = text.length > 0 ? text.length : 1;
  return body.slice(0, at) + body.slice(at + count);
}

async function applyOpReplay(io, id) {
  const page = await io.find('Op', { where: { docId: id }, order: 'at asc', limit: 5000 });
  const ops = page.items || [];
  return { ops, content: ops.reduce((text, op) => applyOpText(text, op.kind, op.pos, op.text), '') };
}

export async function applyOp(input, io) {
  const id = String(input.id || '');
  const clientId = String(input.clientId || '').trim();
  const seq = Number(input.seq);
  const kind = String(input.kind || '');
  const pos = Number(input.pos);
  const text = String(input.text || '');

  if (!clientId || clientId.length > 80) return { error: 'Invalid' };
  if (!Number.isInteger(seq) || seq < 0) return { error: 'Invalid' };
  if (kind !== 'insert' && kind !== 'delete') return { error: 'Invalid' };
  if (!Number.isInteger(pos) || pos < 0) return { error: 'Invalid' };
  if (text.length > 5000) return { error: 'Invalid' };

  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };

  // Retries are the norm on a flaky link: the same (clientId, seq) returns the
  // current text instead of duplicating the character.
  const seen = await io.find('Op', { where: { docId: id, clientId, seq }, limit: 1 });
  if ((seen.items || []).length > 0) {
    const { ops, content } = await applyOpReplay(io, id);
    return { result: { docId: id, version: ops.length, duplicate: true, content } };
  }

  const at = new Date().toISOString();
  // The type requires the field; the authoritative ordinal is computed on read
  // from the ordered log, so a collision here is harmless.
  const before = await io.count('Op', { where: { docId: id } });
  await io.insert('Op', {
    id: await io.new(),
    docId: id,
    clientId,
    seq,
    kind,
    pos,
    text,
    version: before + 1,
    at,
  });

  const { ops, content } = await applyOpReplay(io, id);
  await io.update('Doc', id, { updatedAt: at });
  await io.publish('doc:' + id, { type: 'op', docId: id, version: ops.length, clientId, kind, pos, text, at });

  // Compaction is a job, not part of the request.
  if (ops.length > 0 && ops.length % 20 === 0) await io.queuePublish('compact', { docId: id });

  return { result: { docId: id, version: ops.length, duplicate: false, content } };
}
