// Consumer 2. Markdown is built from the incident row and its event log; the
// object key is the incident id, so a redelivery finds postmortemKey and stops.
export async function postmortemDoc(input, io) {
  const id = String((input && input.incidentId) || input || '');
  if (!id) return { result: { skipped: true } };
  const row = await io.fetch('Incident', id);
  if (!row) return { result: { skipped: true } };
  if (row.postmortemKey) return { result: { key: row.postmortemKey, duplicate: true } };

  const events = await io.find('IncidentEvent', { where: { incidentId: id }, order: 'at asc', limit: 500 });
  const lines = [
    '# ' + row.title,
    '',
    '- service: ' + row.serviceId,
    '- severity: ' + row.severity,
    '- status: ' + row.status,
    '- opened: ' + row.openedAt,
    '- acknowledged: ' + (row.ackedAt || 'never'),
    '- resolved: ' + (row.resolvedAt || ''),
    '- assignee: ' + (row.assignee || 'unassigned'),
    '- alerts folded: ' + row.dedupCount,
    '',
    '## Summary',
    '',
    row.summary || '(none)',
    '',
    '## Timeline',
    ''
  ];
  for (const event of events.items || []) {
    lines.push('- ' + event.at + ' **' + event.kind + '** ' + event.actor + ': ' + event.detail);
  }
  const content = lines.join('\n') + '\n';
  const key = 'postmortems/' + id + '.md';
  await io.blobPut(key, content, 'text/markdown; charset=utf-8');
  await io.update('Incident', id, { postmortemKey: key });
  return { result: { key, bytes: content.length } };
}
