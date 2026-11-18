// Everything currently held, soonest deadline first. The prefix lets one
// client watch its own namespace ("orders/", "tenant-7/").

function flLView(lease) {
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

export async function locks(input, io) {
  const limit = input.limit == null ? 50 : Number(input.limit);
  const prefix = String(input.prefix == null ? '' : input.prefix);
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) return { error: 'Invalid' };

  const now = Date.now();
  const page = await io.find('Lease', { limit: 500 });
  const items = (page && page.items ? page.items : [])
    .filter((lease) => Date.parse(lease.expiresAt) > now)
    .filter((lease) => String(lease.name).startsWith(prefix))
    .sort((left, right) => Date.parse(left.expiresAt) - Date.parse(right.expiresAt));

  return { result: items.slice(0, limit).map(flLView) };
}
