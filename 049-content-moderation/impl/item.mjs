// The full record for the author and the staff: the row plus its decisions and
// appeals. A stranger gets 403, not a redacted version.
export async function item(input, io) {
  const actor = await io.actor();
  const itemId = String(input.itemId || '');
  const row = await io.fetch('Item', itemId);
  if (!row) return { error: 'NotFound' };

  const reviewer = await itFind(io, actor.id);
  if (row.author !== actor.id && !reviewer) return { error: 'Forbidden' };

  const decisions = await io.find('Decision', {
    where: { itemId },
    order: 'createdAt asc',
    limit: 50,
  });
  const appeals = await io.find('Appeal', {
    where: { itemId },
    order: 'createdAt asc',
    limit: 50,
  });
  return {
    result: {
      item: row,
      decisions: decisions.items || [],
      appeals: appeals.items || [],
    },
  };
}

async function itFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
