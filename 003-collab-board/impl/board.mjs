export async function board(input, io) {
  const roomId = String(input.roomId || '');
  const room = await io.fetch('Room', roomId);
  if (!room) return { error: 'NotFound' };

  // The store caps one page at 500 rows; follow the keyset cursor so a busy
  // board is never silently truncated.
  const shapes = [];
  let cursor = null;
  do {
    const query = { where: { roomId }, order: 'id asc', limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('Shape', query);
    for (const shape of page.items || []) {
      if (!shape.deleted) shapes.push(shape);
    }
    cursor = page.next || null;
  } while (cursor);

  return {
    result: { roomId, revision: Number(room.revision) || 0, shapes },
  };
}
