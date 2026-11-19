
export async function stats(input, io) {
  const metric = String(input.metric || '').trim();
  if (!metric) return { error: 'NotFound' };

  const out = [];
  let cursor = null;
  for (let page = 0; page < 20; page += 1) {
    const query = { where: { metric }, order: 'slot asc', limit: 500 };
    if (cursor) query.cursor = cursor;
    const found = await io.find('Bucket', query);
    const items = found.items || [];
    for (const item of items) out.push(item);
    cursor = found.next || null;
    if (!cursor || items.length === 0) break;
  }
  if (out.length === 0) return { error: 'NotFound' };

  const from = out[0].slot;
  const to = out[out.length - 1].slot;
  let cnt = 0;
  let total = 0;
  let lo = Infinity;
  let hi = -Infinity;
  let minSlot = from;
  let maxSlot = to;
  for (const bucket of out) {
    cnt += Number(bucket.cnt || 0);
    total += Number(bucket.total || 0);
    lo = Math.min(lo, Number(bucket.lo));
    hi = Math.max(hi, Number(bucket.hi));
    if (String(bucket.slot) < minSlot) minSlot = String(bucket.slot);
    if (String(bucket.slot) > maxSlot) maxSlot = String(bucket.slot);
  }

  const hour = Math.floor(Date.parse(minSlot) / 3600000) * 3600000;
  return {
    result: {
      metric,
      from: minSlot,
      to: maxSlot,
      step: 3600,
      points: [
        {
          slot: new Date(hour).toISOString(),
          cnt,
          total: Math.round(total * 1e6) / 1e6,
          lo,
          hi,
          mean: cnt === 0 ? 0 : Math.round((total / cnt) * 1e6) / 1e6,
        },
      ],
      missing: 0,
      total: cnt,
    },
  };
}
