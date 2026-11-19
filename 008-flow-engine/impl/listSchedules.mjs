export async function listSchedules(input, io) {
  const page = await io.find('ScheduleRec', { limit: 200 });
  const items = (page.items || []).map((row) => ({
    name: row.name,
    workflow: row.workflow,
    everySeconds: Number(row.everySeconds || 0),
    nextAt: row.nextAt,
    enabled: row.enabled === true,
  }));
  items.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return { result: items };
}
