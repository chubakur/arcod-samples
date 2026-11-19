export async function setMonitor(input, io) {
  const metric = String(input.metric || '').trim();
  const threshold = Number(input.threshold);
  if (!metric || metric.length > 64) return { error: 'Invalid' };
  if (!Number.isFinite(threshold)) return { error: 'Invalid' };

  const found = await io.find('Monitor', { where: { metric }, limit: 1 });
  const existing = (found.items || [])[0];
  const updatedAt = new Date().toISOString();

  if (existing) {
    await io.update('Monitor', existing.id, { threshold, updatedAt });
    return { result: { ...existing, threshold, updatedAt } };
  }

  const id = await io.new();
  try {
    const monitor = { id, metric, threshold, updatedAt };
    await io.insert('Monitor', monitor);
    return { result: monitor };
  } catch (err) {
    const again = await io.find('Monitor', { where: { metric }, limit: 1 });
    const winner = (again.items || [])[0];
    if (winner) {
      await io.update('Monitor', winner.id, { threshold, updatedAt });
      return { result: { ...winner, threshold, updatedAt } };
    }
    return { error: 'Conflict' };
  }
}
