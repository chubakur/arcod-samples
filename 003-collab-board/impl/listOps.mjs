export async function listOps(input, io) {
  const roomId = String(input.roomId || '');
  const room = await io.fetch('Room', roomId);
  if (!room) return { error: 'NotFound' };

  const after = Math.max(0, Number(input.after) || 0);
  const limit = Math.max(1, Math.min(500, Number(input.limit) || 200));
  const page = await io.find('Op', {
    where: { roomId, seq: { gt: after } },
    order: 'seq asc',
    limit,
  });
  return { result: page.items || [] };
}
