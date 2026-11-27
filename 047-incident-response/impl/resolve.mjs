// Resolution is not final until the postmortem job writes the snapshot; the
// operation only starts that work and returns the incident.
export async function resolve(input, io) {
  const id = String(input.id || '');
  const actor = String(input.actor || 'responder').trim() || 'responder';
  const summary = String(input.summary || '').trim();
  const row = await io.fetch('Incident', id);
  if (!row) return { error: 'NotFound', id };
  if (row.status === 'resolved') return { error: 'Conflict', id };

  const at = new Date().toISOString();
  await io.update('Incident', id, { status: 'resolved', resolvedAt: at, summary });
  await io.insert('IncidentEvent', {
    id: await io.new(),
    incidentId: id,
    kind: 'resolved',
    actor,
    detail: summary || 'resolved',
    at
  });
  await io.queuePublish('postmortem', id);
  await io.publish('service:' + row.serviceId, {
    type: 'incident',
    event: 'resolved',
    incidentId: id,
    severity: row.severity,
    status: 'resolved',
    assignee: row.assignee
  });
  return { result: { ...row, status: 'resolved', resolvedAt: at, summary } };
}
