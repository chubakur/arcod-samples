export async function listIncidents(input, io) {
  const status = String(input.status || 'open');
  const limit = Math.min(Math.max(Number(input.limit) || 20, 1), 100);
  const query = { order: 'openedAt desc', limit };
  if (status !== 'all') query.where = { status };
  const page = await io.find('Incident', query);
  return { result: page.items || [] };
}
