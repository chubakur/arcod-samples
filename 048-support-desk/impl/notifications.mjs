// Inbox of the caller, newest first. The rows are written by the consumer, so
// this read never depends on an external mail provider.
export async function notifications(input, io) {
  const actor = await io.actor();
  const unreadOnly = input.unread === true;
  const page = await io.find('Notification', {
    where: { userId: actor.id },
    order: 'createdAt desc',
    limit: 100,
  });
  const out = [];
  for (const row of page.items || []) {
    if (unreadOnly && row.readAt) continue;
    out.push(row);
  }
  return { result: out };
}
