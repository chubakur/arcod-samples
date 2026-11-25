// Queue consumer: turns a durable zone row into an S3 snapshot. The row is
// never edited here; reindexedAt is the only mutable marker.
export async function reindex(input, io) {
  const zoneId = String(input.zoneId || '');
  if (!zoneId) return { result: false };

  let zone = null;
  try {
    zone = await io.fetch('Zone', zoneId);
  } catch {
    return { result: false };
  }
  if (!zone) return { result: false };

  const key = 'zones/' + zoneId + '.json';
  const at = new Date().toISOString();
  await io.blobPut(
    key,
    JSON.stringify({
      id: zone.id,
      name: zone.name,
      polygon: JSON.parse(zone.polygon),
      basePrice: zone.basePrice,
      perKm: zone.perKm,
      at,
    }),
    'application/json',
  );
  await io.update('Zone', zoneId, { reindexedAt: at });
  return { result: true };
}
