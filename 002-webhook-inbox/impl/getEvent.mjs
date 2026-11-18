export async function getEvent(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'Invalid' };
  const found = await io.find('Event', { where: { id }, limit: 1 });
  const event = (found.items || [])[0];
  if (!event) return { error: 'NotFound' };
  return { result: event };
}
