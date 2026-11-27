export async function onCall(input, io) {
  const serviceId = String(input.serviceId || '');
  const service = await io.fetch('Service', serviceId);
  if (!service) return { error: 'NotFound', serviceId };
  const at = input.at ? Date.parse(String(input.at)) : Date.now();
  if (!Number.isFinite(at)) return { error: 'NotFound', serviceId };

  const page = await io.find('Shift', { where: { serviceId }, limit: 500 });
  for (const shift of page.items || []) {
    if (Date.parse(shift.startsAt) <= at && at < Date.parse(shift.endsAt)) {
      return { result: { serviceId, agent: shift.agent, shiftId: shift.id, until: shift.endsAt } };
    }
  }
  return { result: { serviceId, agent: '', shiftId: '', until: null } };
}
