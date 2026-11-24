// The reading row is durable before the queue message exists: a crash between
// the two loses the evaluation, not the sample.
export async function ingest(input, io) {
  const id = String(input.id || '');
  const samples = Array.isArray(input.samples) ? input.samples : null;
  if (!id || !samples || samples.length === 0) return { error: 'Invalid' };
  if (samples.length > 100) return { error: 'Invalid' };

  const device = await io['fetch']('Device', id);
  if (!device) return { error: 'NotFound' };

  const receivedAt = new Date().toISOString();
  let lastSeen = device.lastSeenAt || null;
  let accepted = 0;

  for (const sample of samples) {
    const metric = String(sample.metric || '').trim();
    const value = Number(sample.value);
    const at = String(sample.at || receivedAt);
    if (!metric || metric.length > 60) return { error: 'Invalid' };
    if (!Number.isFinite(value)) return { error: 'Invalid' };
    if (Number.isNaN(Date.parse(at))) return { error: 'Invalid' };

    await io.insert('Reading', {
      id: await io.new(),
      deviceId: id,
      metric,
      value,
      at,
      receivedAt,
    });
    await io.queuePublish('samples', { deviceId: id, metric, value, at });
    if (!lastSeen || Date.parse(at) > Date.parse(lastSeen)) lastSeen = at;
    accepted += 1;
  }

  await io.update('Device', id, { lastSeenAt: lastSeen, status: 'active' });
  return { result: { accepted, deviceId: id, lastSeenAt: lastSeen || receivedAt } };
}
