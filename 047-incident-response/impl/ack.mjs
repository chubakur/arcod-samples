// Ack is idempotent: a pager retry after a lost response must not 409.
export async function ack(input, io) {
  const id = String(input.id || '');
  const actor = String(input.actor || 'responder').trim() || 'responder';
  const row = await io.fetch('Incident', id);
  if (!row) return { error: 'NotFound', id };
  if (row.status === 'resolved') return { error: 'Conflict', id };
  if (row.status === 'acked') return { result: row };

  const at = new Date().toISOString();
  await io.update('Incident', id, { status: 'acked', ackedAt: at });
  await io.insert('IncidentEvent', {
    id: await io.new(),
    incidentId: id,
    kind: 'acknowledged',
    actor,
    detail: actor + ' took the incident',
    at
  });
  await io.publish('service:' + row.serviceId, {
    type: 'incident',
    event: 'acknowledged',
    incidentId: id,
    severity: row.severity,
    status: 'acked',
    assignee: row.assignee
  });
  return { result: { ...row, status: 'acked', ackedAt: at } };
}
