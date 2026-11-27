// Only the owner can mark a notification read; a stranger gets 403 without
// learning the text.
export async function readNotification(input, io) {
  const actor = await io.actor();
  const id = String(input.id || '');
  const row = await io.fetch('Notification', id);
  if (!row) return { error: 'NotFound' };
  if (row.userId !== actor.id) return { error: 'Forbidden' };
  if (row.readAt) return { result: row };

  const now = new Date().toISOString();
  await io.update('Notification', id, { readAt: now });
  return { result: { ...row, readAt: now } };
}
