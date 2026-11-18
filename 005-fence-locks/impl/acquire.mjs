// Take one lease.
//
// Two steps are atomic, and both rely on unique claims rather than on a
// read-modify-write the store cannot do (chubakur/arcod#10):
//   * Fence.slot = "name#number" makes "take the next number" a real claim;
//   * Lease.name makes "there is at most one holder" a real claim.
// Everything else may lose a race: losing it is always a Conflict, never a
// silent double grant.

const flMinMs = 1000;
const flMaxMs = 3600000;

function flIso(ms) {
  return new Date(ms).toISOString();
}

function flView(lease) {
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

function flCode(err) {
  return (err && (err.error || err.name)) || '';
}

async function flTake(io, name, owner, ttlMs) {
  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };
  if (owner.length < 1 || owner.length > 60) return { error: 'Invalid' };
  if (!Number.isInteger(ttlMs) || ttlMs < flMinMs || ttlMs > flMaxMs) return { error: 'Invalid' };

  const now = Date.now();
  const page = await io.find('Lease', { where: { name }, limit: 1 });
  const live = page && page.items ? page.items[0] : null;

  if (live) {
    if (Date.parse(live.expiresAt) > now) return { error: 'Conflict' };
    // Expired. Remove by id, never by name: if a rival already replaced this
    // record, our late cleanup must not delete the fresh one.
    await io.remove('Lease', live.id);
    await io.insert('Trace', {
      id: await io.new(),
      name,
      fence: Number(live.fence),
      kind: 'expired',
      owner: live.owner,
      at: flIso(now),
    });
  }

  let fence = 0;
  for (let attempt = 0; attempt < 8 && fence === 0; attempt += 1) {
    const top = await io.find('Fence', { where: { name }, order: 'fence desc', limit: 1 });
    const last = top && top.items ? top.items[0] : null;
    const next = (last ? Number(last.fence) : 0) + 1;
    try {
      await io.insert('Fence', {
        id: await io.new(),
        name,
        slot: name + '#' + next,
        fence: next,
        owner,
        at: flIso(now),
      });
      fence = next;
    } catch (err) {
      if (flCode(err) !== 'Conflict') throw err;
    }
  }
  if (!fence) return { error: 'Conflict' };

  const token = await io.new();
  const lease = {
    id: await io.new(),
    name,
    owner,
    token,
    fence,
    ttlMs,
    renewals: 0,
    acquiredAt: flIso(now),
    renewedAt: flIso(now),
    expiresAt: flIso(now + ttlMs),
  };

  try {
    await io.insert('Lease', lease);
  } catch (err) {
    // Another contender claimed the name while we were allocating a number.
    // The number stays burned; a fence may skip, it may never go back.
    if (flCode(err) === 'Conflict') return { error: 'Conflict' };
    throw err;
  }

  await io.insert('Trace', {
    id: await io.new(),
    name,
    fence,
    kind: 'acquired',
    owner,
    at: flIso(now),
  });

  return { result: { token, lease: flView(lease) } };
}

export async function acquire(input, io) {
  return flTake(
    io,
    String(input.name == null ? '' : input.name).trim(),
    String(input.owner == null ? '' : input.owner).trim(),
    input.ttlMs == null ? 15000 : Number(input.ttlMs),
  );
}
