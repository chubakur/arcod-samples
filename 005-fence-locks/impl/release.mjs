// Give a lease back early. The fence stays allocated forever: a resource that
// remembers fence 7 must never see a second, unrelated writer claim 7.

function flrIso(ms) {
  return new Date(ms).toISOString();
}

function flrView(lease) {
  return {
    id: lease.id,
    name: lease.name,
    owner: lease.owner,
    fence: lease.fence,
    ttlMs: lease.ttlMs,
    renewals: lease.renewals,
    acquiredAt: lease.acquiredAt,
    renewedAt: lease.renewedAt,
    expiresAt: lease.expiresAt,
  };
}

export async function release(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  const token = String(input.token == null ? '' : input.token);
  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };

  const now = Date.now();
  const page = await io.find('Lease', { where: { name }, limit: 1 });
  const lease = page && page.items ? page.items[0] : null;
  if (!lease) return { error: 'NotFound' };

  if (Date.parse(lease.expiresAt) <= now) {
    await io.remove('Lease', lease.id);
    await io.insert('Trace', {
      id: await io.new(),
      name,
      fence: Number(lease.fence),
      kind: 'expired',
      owner: lease.owner,
      at: flrIso(now),
    });
    return { error: 'NotFound' };
  }

  if (String(lease.token) !== token) return { error: 'Forbidden' };

  await io.remove('Lease', lease.id);
  await io.insert('Trace', {
    id: await io.new(),
    name,
    fence: Number(lease.fence),
    kind: 'released',
    owner: lease.owner,
    at: flrIso(now),
  });

  return { result: flrView(lease) };
}
