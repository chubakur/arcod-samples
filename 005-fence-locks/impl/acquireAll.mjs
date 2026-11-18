// All-or-nothing over a set of names. Names are deduplicated and sorted
// first, so two clients that ask for {a, b} and {b, a} always take them in the
// same order. Deadlock is impossible by construction, not by luck.
//
// The body repeats the single-lock logic on purpose: impl files share one
// module in the generated service, so a top-level helper defined here would
// only collide with the same name in another body (chubakur/arcod#11).

const faMinMs = 1000;
const faMaxMs = 3600000;

function faIso(ms) {
  return new Date(ms).toISOString();
}

function faView(lease) {
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

function faCode(err) {
  return (err && (err.error || err.name)) || '';
}

async function faTake(io, name, owner, ttlMs) {
  const now = Date.now();
  const page = await io.find('Lease', { where: { name }, limit: 1 });
  const live = page && page.items ? page.items[0] : null;

  if (live) {
    if (Date.parse(live.expiresAt) > now) return { error: 'Conflict' };
    await io.remove('Lease', live.id);
    await io.insert('Trace', {
      id: await io.new(),
      name,
      fence: Number(live.fence),
      kind: 'expired',
      owner: live.owner,
      at: faIso(now),
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
        at: faIso(now),
      });
      fence = next;
    } catch (err) {
      if (faCode(err) !== 'Conflict') throw err;
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
    acquiredAt: faIso(now),
    renewedAt: faIso(now),
    expiresAt: faIso(now + ttlMs),
  };

  try {
    await io.insert('Lease', lease);
  } catch (err) {
    if (faCode(err) === 'Conflict') return { error: 'Conflict' };
    throw err;
  }

  await io.insert('Trace', {
    id: await io.new(),
    name,
    fence,
    kind: 'acquired',
    owner,
    at: faIso(now),
  });

  return { result: { token, lease: faView(lease) } };
}

async function faDrop(io, name, token) {
  const page = await io.find('Lease', { where: { name }, limit: 1 });
  const lease = page && page.items ? page.items[0] : null;
  if (!lease || String(lease.token) !== token) return;
  await io.remove('Lease', lease.id);
  await io.insert('Trace', {
    id: await io.new(),
    name,
    fence: Number(lease.fence),
    kind: 'released',
    owner: lease.owner,
    at: faIso(Date.now()),
  });
}

export async function acquireAll(input, io) {
  const owner = String(input.owner == null ? '' : input.owner).trim();
  const ttlMs = input.ttlMs == null ? 15000 : Number(input.ttlMs);
  const raw = Array.isArray(input.names) ? input.names : [];

  if (raw.length < 1 || raw.length > 10) return { error: 'Invalid' };
  if (owner.length < 1 || owner.length > 60) return { error: 'Invalid' };
  if (!Number.isInteger(ttlMs) || ttlMs < faMinMs || ttlMs > faMaxMs) return { error: 'Invalid' };

  const names = [];
  for (const item of raw) {
    const name = String(item == null ? '' : item).trim();
    if (name.length < 1 || name.length > 120) return { error: 'Invalid' };
    if (!names.includes(name)) names.push(name);
  }
  names.sort();

  const grants = [];
  for (const name of names) {
    const taken = await faTake(io, name, owner, ttlMs);
    if (taken.error) {
      // Roll back in reverse order: the caller asked for a set, and a set it
      // did not get fully is not a set it may keep.
      for (let index = grants.length - 1; index >= 0; index -= 1) {
        await faDrop(io, grants[index].lease.name, grants[index].token);
      }
      return { error: taken.error };
    }
    grants.push(taken.result);
  }

  return { result: grants };
}
