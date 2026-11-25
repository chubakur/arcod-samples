export async function addZone(input, io) {
  const name = String(input.name || '').trim();
  const raw = String(input.polygon || '').trim();
  const basePrice = Number(input.basePrice);
  const perKm = Number(input.perKm);

  if (!name || name.length > 80) return { error: 'Invalid' };
  if (!Number.isInteger(basePrice) || basePrice < 0 || basePrice > 100000) return { error: 'Invalid' };
  if (!Number.isInteger(perKm) || perKm < 0 || perKm > 10000) return { error: 'Invalid' };

  let points;
  try {
    points = JSON.parse(raw);
  } catch {
    return { error: 'Invalid' };
  }
  if (!Array.isArray(points) || points.length < 3 || points.length > 500) return { error: 'Invalid' };
  for (const point of points) {
    if (!Array.isArray(point) || point.length !== 2) return { error: 'Invalid' };
    const lng = Number(point[0]);
    const lat = Number(point[1]);
    if (!Number.isFinite(lng) || lng < -180 || lng > 180) return { error: 'Invalid' };
    if (!Number.isFinite(lat) || lat < -90 || lat > 90) return { error: 'Invalid' };
  }

  // Pre-check the unique name: a raw unique violation currently leaves the
  // generated service's SQL connection checked out and the whole process
  // stops answering (issue filed against arcod). The unique rule stays as the
  // final arbiter for the race between two creators.
  const existing = await io.find('Zone', { where: { name }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const id = await io.new();
  const zone = {
    id,
    name,
    polygon: JSON.stringify(points),
    basePrice,
    perKm,
    active: true,
    createdAt: new Date().toISOString(),
  };
  try {
    await io.insert('Zone', zone);
  } catch (error) {
    if (error && (error.error === 'Conflict' || error.name === 'Conflict')) return { error: 'Conflict' };
    throw error;
  }

  // Durable SQL row first, reindex event second: the consumer writes the S3
  // snapshot and stamps reindexedAt. A failed publish leaves the row visible
  // as "not reindexed" instead of pretending the snapshot exists.
  await io.queuePublish('reindex', id);
  return { result: zone };
}
