// The consumer flips the comment to notified and tells the live topic. A
// redelivery is harmless: the status check makes it a no-op.
export async function notify(input, io) {
  const id = String(input.commentId || '');
  if (!id) return;
  const row = await io.fetch('Comment', id);
  if (!row || row.status === 'notified') return;
  await io.update('Comment', id, { status: 'notified' });
  await io.publish('doc:' + String(row.docId || ''), {
    type: 'comment-status',
    docId: row.docId,
    commentId: id,
    status: 'notified',
  });
  return { ok: true };
}
