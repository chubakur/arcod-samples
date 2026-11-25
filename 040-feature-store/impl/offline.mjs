// Offline reads scan the durable rows; object storage keeps the immutable
// per-event copy that exports and backfills use.
export async function offline(input, io) {
  const feature = String(input.feature || '').trim();
  const entityId = String(input.entityId || '').trim();
  if (!feature || !entityId) return { result: [] };

  const found = await io.find('Event', { where: { feature, entityId }, limit: 1000 });
  const items = (found.items || [])
    .slice()
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at))
    .map((row) => ({
      eventId: row.id,
      feature: row.feature,
      entityId: row.entityId,
      value: String(row.value),
      at: row.at,
      version: Number(row.version || 1),
    }));
  return { result: items };
}
