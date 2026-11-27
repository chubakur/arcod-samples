export async function incident(input, io) {
  const id = String(input.id || '');
  const row = await io.fetch('Incident', id);
  if (!row) return { error: 'NotFound', id };
  const page = await io.find('IncidentEvent', { where: { incidentId: id }, order: 'at asc', limit: 500 });
  return { result: { incident: row, events: page.items || [] } };
}
