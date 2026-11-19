const STEPS = new Set([60, 300, 900, 3600]);

function seriesIso(ms) {
  return new Date(ms).toISOString();
}

async function allBuckets(io, metric) {
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
  return out;
}

export async function series(input, io) {
  const metric = String(input.metric || '').trim();
  if (!metric) return { error: 'Invalid' };

  const fromMs = Date.parse(String(input.from || ''));
  const toMs = Date.parse(String(input.to || ''));
  const step = Number(input.step == null ? 60 : input.step);
  if (!Number.isFinite(fromMs) || !Number.isFinite(toMs)) return { error: 'Invalid' };
  if (toMs <= fromMs) return { error: 'Invalid' };
  if (toMs - fromMs > 366 * 24 * 3600 * 1000) return { error: 'Invalid' };
  if (!STEPS.has(step)) return { error: 'Invalid' };

  const buckets = await allBuckets(io, metric);
  if (buckets.length === 0) return { error: 'NotFound' };

  const groups = new Map();
  let total = 0;
  for (const bucket of buckets) {
    const at = Date.parse(String(bucket.slot));
    if (!Number.isFinite(at) || at < fromMs || at > toMs) continue;
    const key = Math.floor(at / (step * 1000)) * step * 1000;
    const cnt = Number(bucket.cnt || 0);
    const sum = Number(bucket.total || 0);
    const lo = Number(bucket.lo);
    const hi = Number(bucket.hi);
    const acc = groups.get(key);
    if (!acc) {
      groups.set(key, { slot: seriesIso(key), cnt, total: sum, lo, hi });
    } else {
      acc.cnt += cnt;
      acc.total += sum;
      acc.lo = Math.min(acc.lo, lo);
      acc.hi = Math.max(acc.hi, hi);
    }
    total += cnt;
  }

  const points = Array.from(groups.keys())
    .sort((a, b) => a - b)
    .map((key) => {
      const acc = groups.get(key);
      return {
        slot: acc.slot,
        cnt: acc.cnt,
        total: Math.round(acc.total * 1e6) / 1e6,
        lo: acc.lo,
        hi: acc.hi,
        mean: acc.cnt === 0 ? 0 : Math.round((acc.total / acc.cnt) * 1e6) / 1e6,
      };
    });

  const expected = Math.max(1, Math.floor((toMs - fromMs) / (step * 1000)) + 1);
  return {
    result: {
      metric,
      from: seriesIso(fromMs),
      to: seriesIso(toMs),
      step,
      points,
      missing: Math.max(0, expected - points.length),
      total,
    },
  };
}
