// A pending attempt older than five minutes means the score message was lost
// (a publish before a crash, a broker restart). Republishing is safe: the
// consumer skips an attempt that already has a decision.
const FRK_STALE_MS = 5 * 60 * 1000;

export async function sweep(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const now = body.now ? Date.parse(String(body.now)) : Date.now();
  if (!Number.isFinite(now)) return { result: { stale: 0, rescored: 0 } };

  const page = await io.find('Attempt', { where: { status: 'pending' }, limit: 500 });
  let stale = 0;
  let rescored = 0;
  for (const row of page.items || []) {
    if (now - Date.parse(row.createdAt) < FRK_STALE_MS) continue;
    stale += 1;
    await io.queuePublish('score', row.id);
    rescored += 1;
  }
  return { result: { stale, rescored } };
}
