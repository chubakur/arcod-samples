// The stale window is generous: a run that takes longer than an hour is a
// runner that died, not a slow model. Marking it failed unblocks the queue's
// accounting; a redelivery sees a final status and does nothing.
const SW_WINDOW_MS = 3600 * 1000;

export async function sweep(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const now = body.now ? new Date(String(body.now)) : new Date();
  const cutoff = new Date(now.getTime() - SW_WINDOW_MS).toISOString();

  const page = await io.find('Run', { where: { status: 'running' }, order: 'startedAt asc', limit: 200 });
  let stale = 0;
  for (const run of page.items || []) {
    const started = run.startedAt ? String(run.startedAt) : '';
    if (started && started >= cutoff) continue;
    await io.update('Run', run.id, {
      status: 'failed',
      error: 'stale: runner stopped mid-run',
      finishedAt: now.toISOString(),
    });
    stale += 1;
  }
  return { result: { stale, invoiced: 0 } };
}
