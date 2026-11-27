export async function stats(input, io) {
  const services = await io.count('Service', {});
  const open = await io.count('Incident', { where: { status: 'open' } });
  const acked = await io.count('Incident', { where: { status: 'acked' } });
  const resolved = await io.count('Incident', { where: { status: 'resolved' } });
  const page = await io.find('Incident', { limit: 500 });
  let deduped = 0;
  let mttaTotal = 0;
  let mttaCount = 0;
  for (const row of page.items || []) {
    deduped += Number(row.dedupCount || 0) - 1 > 0 ? Number(row.dedupCount) - 1 : 0;
    if (row.ackedAt) {
      const delta = (Date.parse(row.ackedAt) - Date.parse(row.openedAt)) / 1000;
      if (Number.isFinite(delta) && delta >= 0) {
        mttaTotal += delta;
        mttaCount += 1;
      }
    }
  }
  const mttaSeconds = mttaCount ? Math.round(mttaTotal / mttaCount) : 0;
  return { result: { services, open, acked, resolved, deduped, mttaSeconds } };
}
