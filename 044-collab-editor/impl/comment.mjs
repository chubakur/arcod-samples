export async function comment(input, io) {
  const id = String(input.id || '');
  const author = String(input.author || '').trim();
  const body = String(input.body || '').trim();
  if (!author || author.length > 120) return { error: 'Invalid' };
  if (!body || body.length > 2000) return { error: 'Invalid' };

  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };

  const at = new Date().toISOString();
  const row = {
    id: await io.new(),
    docId: id,
    author,
    body,
    status: 'pending',
    createdAt: at,
  };
  // The row is durable before the queue message: a lost notification must not
  // lose the comment.
  await io.insert('Comment', row);
  await io.publish('doc:' + id, { type: 'comment', docId: id, commentId: row.id, author, at });
  await io.queuePublish('notify', { commentId: row.id });
  return { result: { comment: row, notified: true } };
}
