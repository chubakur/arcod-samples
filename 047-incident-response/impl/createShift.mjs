// Overlap is checked here, not by a unique index: an interval has no single
// column to make unique. The service row is fetched first so a typo is 404.
export async function createShift(input, io) {
  const serviceId = String(input.serviceId || '');
  const agent = String(input.agent || '').trim();
  const startsAt = String(input.startsAt || '');
  const endsAt = String(input.endsAt || '');
  const start = Date.parse(startsAt);
  const end = Date.parse(endsAt);
  const service = await io.fetch('Service', serviceId);
  if (!service) return { error: 'NotFound', serviceId };
  if (!agent || agent.length > 80) return { error: 'Invalid', startsAt };
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return { error: 'Invalid', startsAt };

  const page = await io.find('Shift', { where: { serviceId }, limit: 500 });
  for (const shift of page.items || []) {
    const otherStart = Date.parse(shift.startsAt);
    const otherEnd = Date.parse(shift.endsAt);
    if (start < otherEnd && otherStart < end) return { error: 'Conflict', startsAt };
  }

  const row = {
    id: await io.new(),
    serviceId,
    agent,
    startsAt: new Date(start).toISOString(),
    endsAt: new Date(end).toISOString()
  };
  await io.insert('Shift', row);
  return { result: row };
}
