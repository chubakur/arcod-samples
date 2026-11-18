export async function listEvents(input, io) {
  const source = input.source == null ? '' : String(input.source).trim();
  const status = input.status == null ? '' : String(input.status).trim();
  const rawLimit = input.limit == null ? 50 : Number(input.limit);
  const limit = Number.isFinite(rawLimit) && rawLimit > 0 ? Math.min(200, Math.floor(rawLimit)) : 50;

  const where = {};
  if (source) where.source = source;
  if (status) where.status = status;

  const page = await io.find('Event', { where, order: 'receivedAt desc', limit });
  return { result: { items: page.items || [], next: page.next || null } };
}
