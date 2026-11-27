export async function createService(input, io) {
  const name = String(input.name || '').trim();
  const tier = String(input.tier || 'T2').toUpperCase();
  const runbook = String(input.runbook || '').trim();
  if (!name || name.length > 100) return { error: 'Invalid', name };
  if (!['T1', 'T2', 'T3'].includes(tier)) return { error: 'Invalid', name };
  const row = {
    id: await io.new(),
    name,
    tier,
    runbook,
    createdAt: new Date().toISOString()
  };
  try {
    await io.insert('Service', row);
  } catch (error) {
    if (error && (error.error === 'Conflict' || error.name === 'Conflict')) return { error: 'Conflict', name };
    throw error;
  }
  return { result: row };
}
