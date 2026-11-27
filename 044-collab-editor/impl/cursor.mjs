// Cursors are ephemeral: one publish, no row. delivered is the number of
// sockets on the topic at this instant, 0 is a normal answer.
export async function cursor(input, io) {
  const id = String(input.id || '');
  const clientId = String(input.clientId || '').trim();
  const pos = Number(input.pos);
  const name = String(input.name || '').trim().slice(0, 80);
  if (!clientId || clientId.length > 80) return { error: 'Invalid' };
  if (!Number.isInteger(pos) || pos < 0) return { error: 'Invalid' };

  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };

  const delivered = await io.publish('doc:' + id, {
    type: 'cursor',
    docId: id,
    clientId,
    pos,
    name,
    version: doc.version,
  });
  return { result: { delivered: Number(delivered) || 0, version: doc.version } };
}
