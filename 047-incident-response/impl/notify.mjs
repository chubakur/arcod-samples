// Consumer 1. The incident row decides everything: a redelivery finds the
// assignment event and returns without a second timeline entry.
export async function notify(input, io) {
  const id = String((input && input.incidentId) || input || '');
  if (!id) return { result: { skipped: true } };
  const incident = await io.fetch('Incident', id);
  if (!incident) return { result: { skipped: true } };
  if (incident.status !== 'open') return { result: { skipped: true, status: incident.status } };

  const seen = await io.find('IncidentEvent', { where: { incidentId: id, kind: 'assigned' }, limit: 1 });
  if ((seen.items || []).length > 0) {
    return { result: { assigned: String(incident.assignee || ''), duplicate: true } };
  }

  const page = await io.find('Shift', { where: { serviceId: incident.serviceId }, limit: 500 });
  const at = Date.parse(incident.openedAt);
  const shift = (page.items || []).find(
    (row) => Date.parse(row.startsAt) <= at && at < Date.parse(row.endsAt)
  );
  const assignee = shift ? shift.agent : '';
  await io.update('Incident', id, { assignee });
  await io.insert('IncidentEvent', {
    id: await io.new(),
    incidentId: id,
    kind: assignee ? 'assigned' : 'unassigned',
    actor: 'system',
    detail: assignee ? assignee + ' via shift ' + shift.id : 'no shift covers the alert time',
    at: new Date().toISOString()
  });
  await io.publish('service:' + incident.serviceId, {
    type: 'incident',
    event: 'assigned',
    incidentId: id,
    severity: incident.severity,
    status: incident.status,
    assignee
  });
  return { result: { assigned: assignee } };
}
