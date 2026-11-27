export async function ticket(input, io) {
  const playerId = String(input.playerId || '');
  const page = await io.find('QueueTicket', {
    where: { playerId },
    order: 'createdAt desc',
    limit: 1
  });
  const row = (page.items || [])[0];
  if (!row) return { error: 'NotFound', playerId };
  return { result: row };
}
