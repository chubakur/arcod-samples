// The latest human decision. The author may read it as part of the appeal
// record; there is no separate visibility rule beyond the item check.
export async function contentDecision(input, io) {
  const actor = await io.actor();
  const itemId = String(input.itemId || '');
  const row = await io.fetch('Item', itemId);
  if (!row) return { error: 'NotFound' };

  const reviewer = await cdFind(io, actor.id);
  if (row.author !== actor.id && !reviewer) return { error: 'Forbidden' };

  const page = await io.find('Decision', {
    where: { itemId },
    order: 'createdAt desc',
    limit: 1,
  });
  const last = (page.items || [])[0] || null;
  if (!last) return { error: 'NotFound' };
  return { result: last };
}

async function cdFind(io, userId) {
  const page = await io.find('Reviewer', { where: { userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
