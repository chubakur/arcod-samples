async function exportBuckets(io, metric) {
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

export async function publishExport(input, io) {
  const metric = String(input.metric || '').trim();
  if (!metric) return { error: 'Invalid' };
  const fromMs = Date.parse(String(input.from || ''));
  const toMs = Date.parse(String(input.to || ''));
  if (!Number.isFinite(fromMs) || !Number.isFinite(toMs) || toMs <= fromMs) {
    return { error: 'Invalid' };
  }

  const buckets = await exportBuckets(io, metric);
  const rows = [];
  for (const bucket of buckets) {
    const at = Date.parse(String(bucket.slot));
    if (!Number.isFinite(at) || at < fromMs || at > toMs) continue;
    rows.push({
      slot: bucket.slot,
      cnt: Number(bucket.cnt || 0),
      total: Number(bucket.total || 0),
      lo: Number(bucket.lo),
      hi: Number(bucket.hi),
      mean:
        Number(bucket.cnt || 0) === 0
          ? 0
          : Math.round((Number(bucket.total) / Number(bucket.cnt)) * 1e6) / 1e6,
    });
  }
  if (rows.length === 0) return { error: 'NotFound' };

  const body = rows.map((row) => JSON.stringify(row)).join('\n') + '\n';
  const id = await io.new();
  const objectKey = 'exports/' + metric + '/' + id + '.jsonl';
  await io.blobPut(objectKey, body, 'application/x-ndjson');

  const rec = {
    id,
    metric,
    from: new Date(fromMs).toISOString(),
    to: new Date(toMs).toISOString(),
    objectKey,
    lines: rows.length,
    bytes: Buffer.byteLength(body, 'utf8'),
    createdAt: new Date().toISOString(),
  };
  await io.insert('ExportRec', rec);
  return { result: rec };
}
