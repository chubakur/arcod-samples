const ROLLUP_MINUTE = 60000;

function rollupSlot(iso) {
  const at = Date.parse(iso);
  if (!Number.isFinite(at)) return null;
  return new Date(Math.floor(at / ROLLUP_MINUTE) * ROLLUP_MINUTE).toISOString();
}

export async function rollup(input, io) {
  // The runtime hands a single-parameter job { batchId } — accept a bare id too.
  const id = String(typeof input === 'string' ? input : (input && input.batchId) || '');
  if (!id) return { result: false };

  const batch = await io['fetch']('Batch', id);
  if (!batch) return { result: false };
  if (batch.status === 'rolled') return { result: true };

  const found = await io.find('Point', { where: { batch: id }, limit: 500 });
  const points = found.items || [];
  if (points.length === 0) {
    await io.update('Batch', id, { status: 'rolled' });
    return { result: true };
  }

  const groups = new Map();
  for (const point of points) {
    const slot = rollupSlot(String(point.ts)) || String(point.slot);
    const value = Number(point.value);
    const acc = groups.get(slot);
    if (!acc) {
      groups.set(slot, { cnt: 1, total: value, lo: value, hi: value });
    } else {
      acc.cnt += 1;
      acc.total += value;
      acc.lo = Math.min(acc.lo, value);
      acc.hi = Math.max(acc.hi, value);
    }
  }

  const metric = String(batch.metric);
  const updatedAt = new Date().toISOString();
  for (const [slot, acc] of groups) {
    const known = await io.find('Bucket', { where: { metric, slot }, limit: 1 });
    const bucket = (known.items || [])[0];
    if (bucket) {
      await io.update('Bucket', bucket.id, {
        cnt: Number(bucket.cnt || 0) + acc.cnt,
        total: Number(bucket.total || 0) + acc.total,
        lo: Math.min(Number(bucket.lo), acc.lo),
        hi: Math.max(Number(bucket.hi), acc.hi),
        updatedAt,
      });
    } else {
      await io.insert('Bucket', {
        id: await io.new(),
        metric,
        slot,
        cnt: acc.cnt,
        total: acc.total,
        lo: acc.lo,
        hi: acc.hi,
        updatedAt,
      });
    }
  }

  await io.update('Batch', id, { status: 'rolled' });

  const monitor = await io.find('Monitor', { where: { metric }, limit: 1 });
  const watched = (monitor.items || [])[0];
  if (watched) {
    const threshold = Number(watched.threshold);
    let peak = null;
    for (const [slot, acc] of groups) {
      if (acc.hi > threshold && (!peak || acc.hi > peak.hi)) peak = { slot, hi: acc.hi };
    }
    if (peak) {
      const alert = {
        id: await io.new(),
        metric,
        slot: peak.slot,
        hi: peak.hi,
        threshold,
        sentAt: new Date().toISOString(),
      };
      await io.insert('Alert', alert);
      try {
        await io.remote('Alerter', 'notify', alert);
      } catch (err) {
        // The alert stays in the table; a delivery retry is the operator's call.
      }
    }
  }

  return { result: true };
}
