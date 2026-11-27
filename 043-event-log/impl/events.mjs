export async function events(input, io) {
  const streamId = String(input.streamId || '');
  const raw = Number(input.limit);
  const limit = Number.isInteger(raw) && raw > 0 ? Math.min(raw, 200) : 50;
  const page = await io.find('Event', {
    where: { streamId },
    order: 'seq asc',
    limit,
  });
  return { result: page.items || [] };
}
