export async function cancelQueue(input, io) {
  const playerId = String(input.playerId || '');
  const page = await io.find('QueueTicket', {
    where: { playerId, status: 'waiting' },
    limit: 1
  });
  const row = (page.items || [])[0];
  if (!row) return { error: 'NotFound', playerId };

  const updated = await io.update('QueueTicket', row.id, {
    status: 'cancelled',
    updatedAt: new Date().toISOString()
  });
  await io.remove('QueueLock', playerId);
  return { result: updated || { ...row, status: 'cancelled' } };
}
