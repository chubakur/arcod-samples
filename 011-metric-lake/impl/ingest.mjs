const INGEST_MINUTE = 60000;

function slotOf(ms) {
  return new Date(Math.floor(ms / INGEST_MINUTE) * INGEST_MINUTE).toISOString();
}

function metricOk(metric) {
  return /^[a-z0-9][a-z0-9_.:-]{0,63}$/i.test(metric);
}

export async function ingest(input, io) {
  const metric = String(input.metric || '').trim();
  const idem = String(input.idem || '').trim();
  const samples = Array.isArray(input.samples) ? input.samples : [];

  if (!metricOk(metric)) return { error: 'Invalid' };
  if (!idem || idem.length > 128) return { error: 'Invalid' };
  if (samples.length < 1 || samples.length > 120) return { error: 'Invalid' };

  const now = Date.now();
  const clean = [];
  for (const raw of samples) {
    const ts = Date.parse(String((raw && raw.ts) || ''));
    const value = Number(raw && raw.value);
    if (!Number.isFinite(ts)) return { error: 'Invalid' };
    if (!Number.isFinite(value) || Math.abs(value) > 1e12) return { error: 'Invalid' };
    if (ts > now + 5 * INGEST_MINUTE) return { error: 'Invalid' };
    if (ts < now - 30 * 24 * 60 * INGEST_MINUTE) return { error: 'Invalid' };
    clean.push({ ts, value });
  }

  const seen = await io.find('Batch', { where: { metric, idem }, limit: 1 });
  const prior = (seen.items || [])[0];
  if (prior) {
    return {
      result: {
        batchId: prior.id,
        accepted: Number(prior.cnt || 0),
        duplicate: true,
        first: prior.first,
        last: prior.last,
      },
    };
  }

  const batchId = await io.new();
  const first = new Date(clean[0].ts).toISOString();
  const last = new Date(clean[clean.length - 1].ts).toISOString();

  try {
    await io.insert('Batch', {
      id: batchId,
      metric,
      idem,
      cnt: clean.length,
      status: 'queued',
      first,
      last,
      receivedAt: new Date(now).toISOString(),
    });
  } catch (err) {
    // Two writers raced on (metric, idem): the loser reports the winner's batch.
    const again = await io.find('Batch', { where: { metric, idem }, limit: 1 });
    const winner = (again.items || [])[0];
    if (winner) {
      return {
        result: {
          batchId: winner.id,
          accepted: Number(winner.cnt || 0),
          duplicate: true,
          first: winner.first,
          last: winner.last,
        },
      };
    }
    return { error: 'Conflict' };
  }

  for (const point of clean) {
    await io.insert('Point', {
      id: await io.new(),
      metric,
      batch: batchId,
      slot: slotOf(point.ts),
      ts: new Date(point.ts).toISOString(),
      value: point.value,
    });
  }

  await io.queuePublish('rollup', batchId);
  return {
    result: { batchId, accepted: clean.length, duplicate: false, first, last },
  };
}
