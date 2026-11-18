// Extend a lease you still hold. An expired lease is cleaned up here, so a
// polling client never needs a background sweeper (and Arcod has no "after"
// trigger to build one: chubakur/arcod#12).

function frIso(ms) {
  return new Date(ms).toISOString();
}

function frView(lease) {
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

export async function renew(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  const token = String(input.token == null ? '' : input.token);
  const wanted = input.ttlMs == null ? 0 : Number(input.ttlMs);

  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };
  if (wanted !== 0 && (!Number.isInteger(wanted) || wanted < 1000 || wanted > 3600000)) {
    return { error: 'Invalid' };
  }
  if (token.length < 1) return { error: 'Forbidden' };

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
      at: frIso(now),
    });
    return { error: 'NotFound' };
  }

  if (String(lease.token) !== token) return { error: 'Forbidden' };

  const windowMs = wanted > 0 ? wanted : Number(lease.ttlMs);
  const patch = {
    ttlMs: windowMs,
    renewals: Number(lease.renewals || 0) + 1,
    renewedAt: frIso(now),
    expiresAt: frIso(now + windowMs),
  };
  const updated = await io.update('Lease', lease.id, patch);
  return { result: frView(updated || Object.assign({}, lease, patch)) };
}
