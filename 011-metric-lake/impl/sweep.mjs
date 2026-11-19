const SWEEP_MINUTE = 60000;

export async function sweep(input, io) {
  const horizonHours = Number(input.horizonHours == null ? 24 : input.horizonHours);
  if (!Number.isInteger(horizonHours) || horizonHours < 1 || horizonHours > 24 * 365) {
    return { error: 'Invalid' };
  }

  const at = Date.now();
  const cutoff = new Date(at - horizonHours * 3600 * 1000).toISOString();

  let points = 0;
  for (let round = 0; round < 40; round += 1) {
    const page = await io.find('Point', { order: 'slot asc', limit: 500 });
    const items = (page.items || []).filter((item) => String(item.slot) < cutoff);
    if (items.length === 0) break;
    for (const item of items) {
      const gone = await io.remove('Point', item.id);
      if (gone !== false) points += 1;
    }
    if ((page.items || []).length < 500) break;
  }

  let buckets = 0;
  for (let round = 0; round < 40; round += 1) {
    const page = await io.find('Bucket', { order: 'slot asc', limit: 500 });
    const items = (page.items || []).filter((item) => String(item.slot) < cutoff);
    if (items.length === 0) break;
    for (const item of items) {
      const gone = await io.remove('Bucket', item.id);
      if (gone !== false) buckets += 1;
    }
    if ((page.items || []).length < 500) break;
  }

  const stamp = new Date(at).toISOString();
  const report = 'retention/' + stamp.replace(/[:.]/g, '-') + '.json';
  const payload = JSON.stringify({ cutoff, horizonHours, points, buckets, at: stamp });
  await io.blobPut(report, payload, 'application/json');

  return { result: { horizonHours, cutoff, points, buckets, report, at: stamp } };
}
