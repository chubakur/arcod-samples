// A user's inbox. The unread filter is applied in the body because a null
// comparison is not a valid store filter.
export async function notifications(input, io) {
  const actor = await io.actor();
  const page = await io.find('Notification', {
    where: { userId: actor.id },
    order: 'createdAt desc',
    limit: 200,
  });
  let rows = page.items || [];
  if (input.unread === true) rows = rows.filter((row) => !row.readAt);
  return { result: rows };
}
