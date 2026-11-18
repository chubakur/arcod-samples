// Who holds it right now? Expired leases are settled on read, so the answer
// is the truth as of this call, not as of the last write.

function fsIso(ms) {
  return new Date(ms).toISOString();
}

function fsView(lease) {
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

export async function state(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  if (name.length < 1 || name.length > 120) return { error: 'Invalid' };

  const now = Date.now();
  const page = await io.find('Lease', { where: { name }, limit: 1 });
  const lease = page && page.items ? page.items[0] : null;

  let held = false;
  if (lease) {
    if (Date.parse(lease.expiresAt) > now) {
      held = true;
    } else {
      await io.remove('Lease', lease.id);
      await io.insert('Trace', {
        id: await io.new(),
        name,
        fence: Number(lease.fence),
        kind: 'expired',
        owner: lease.owner,
        at: fsIso(now),
      });
    }
  }

  const traces = await io.find('Trace', { where: { name }, order: 'fence desc', limit: 1 });
  const lastTrace = traces && traces.items ? traces.items[0] : null;
  const fence = held ? Number(lease.fence) : (lastTrace ? Number(lastTrace.fence) : 0);

  return {
    result: {
      name,
      held,
      fence,
      lease: held ? fsView(lease) : null,
    },
  };
}
