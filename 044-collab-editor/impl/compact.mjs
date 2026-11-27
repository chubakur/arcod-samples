// Same replay as the explicit snapshot, but on the queue. A redelivery finds
// the Revision row for this version and stops.
function compactReplay(content, op) {
  const body = String(content || '');
  const at = Math.min(Math.max(Number(op.pos) || 0, 0), body.length);
  if (op.kind === 'insert') return body.slice(0, at) + String(op.text || '') + body.slice(at);
  const count = String(op.text || '').length || 1;
  return body.slice(0, at) + body.slice(at + count);
}

export async function compact(input, io) {
  const id = String(input.docId || '');
  if (!id) return { ok: true, skipped: true };
  const doc = await io.fetch('Doc', id);
  if (!doc) return { ok: true, skipped: true };

  const page = await io.find('Op', { where: { docId: id }, order: 'at asc', limit: 5000 });
  const ops = page.items || [];
  const version = ops.length;

  const done = await io.find('Revision', { where: { docId: id, version }, limit: 1 });
  if ((done.items || []).length > 0) return { ok: true, skipped: true };

  const content = ops.reduce(compactReplay, '');
  const key = 'docs/' + id + '/snapshot-' + version + '.json';

  await io.blobPut(key, JSON.stringify({ docId: id, version, content }), 'application/json');
  await io.update('Doc', id, { snapshotKey: key, snapshotVersion: version });
  await io.insert('Revision', {
    id: await io.new(),
    docId: id,
    version,
    key,
    ops: ops.length,
    createdAt: new Date().toISOString(),
  });
  await io.publish('doc:' + id, { type: 'snapshot', docId: id, version, key, background: true });
  return { ok: true };
}
