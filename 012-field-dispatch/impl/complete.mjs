export async function complete(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };

  const ticket = await io.fetch('Ticket', id);
  if (!ticket) return { error: 'NotFound' };
  if (ticket.status === 'done') return { error: 'Conflict' };

  const photos = Array.isArray(input.photos) ? input.photos : [];
  const keys = [];
  for (const photo of photos) {
    const key = String(photo && photo.key ? photo.key : '').trim();
    if (!key) continue;
    const body = String(photo.body == null ? '' : photo.body);
    const type = String(photo.type || 'text/plain');
    await io.blobPut('ticket/' + id + '/' + key, body, type);
    keys.push(key);
  }

  const closedAt = new Date().toISOString();
  const patch = {
    status: 'done',
    note: String(input.note || ''),
    photoKeys: keys.join(','),
    closedAt,
  };
  await io.update('Ticket', id, patch);
  await io.queuePublish('notify', id);

  return { result: { ...ticket, ...patch } };
}
