// An author only ever sees his own submissions; reviewers use /v1/queue.
export async function myItems(input, io) {
  const actor = await io.actor();
  const limit = Number(input.limit);
  const page = await io.find('Item', {
    where: { author: actor.id },
    order: 'createdAt desc',
    limit: Number.isInteger(limit) && limit > 0 ? Math.min(limit, 200) : 50,
  });
  return { result: page.items || [] };
}
