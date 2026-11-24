// Registration is idempotent by (name, site): a re-flashed gateway sends the
// same pair and gets 409 instead of a second device row.
export async function addDevice(input, io) {
  const name = String(input.name || '').trim();
  const site = String(input.site || '').trim();
  const kind = String(input.kind || '').trim() || 'sensor';

  if (!name || name.length > 120) return { error: 'Invalid' };
  if (!site || site.length > 120) return { error: 'Invalid' };
  if (kind.length > 40) return { error: 'Invalid' };

  const existing = await io.find('Device', { where: { name, site }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const device = {
    id: await io.new(),
    name,
    site,
    kind,
    status: 'active',
    lastSeenAt: null,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Device', device);
  return { result: device };
}
