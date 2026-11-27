// Replaying the log is the only way to prove the materialised text is right.
function snapshotReplay(content, op) {
  const body = String(content || '');
  const at = Math.min(Math.max(Number(op.pos) || 0, 0), body.length);
  if (op.kind === 'insert') return body.slice(0, at) + String(op.text || '') + body.slice(at);
  const count = String(op.text || '').length || 1;
  return body.slice(0, at) + body.slice(at + count);
}

export async function snapshot(input, io) {
  const id = String(input.id || '');
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };

  const page = await io.find('Op', { where: { docId: id }, order: 'at asc', limit: 5000 });
  const ops = page.items || [];
  const content = ops.reduce(snapshotReplay, '');
  const version = ops.length;
  const key = 'docs/' + id + '/snapshot-' + version + '.json';

  await io.blobPut(key, JSON.stringify({ docId: id, version, content }), 'application/json');
  await io.update('Doc', id, { snapshotKey: key, snapshotVersion: version, updatedAt: new Date().toISOString() });
  await io.insert('Revision', {
    id: await io.new(),
    docId: id,
    version,
    key,
    ops: ops.length,
    createdAt: new Date().toISOString(),
  });
  await io.publish('doc:' + id, { type: 'snapshot', docId: id, version, key });
  return { result: { docId: id, version, key, content } };
}
