// Cancellation is cooperative: a queued run stops before the consumer touches
// it, a running one is flagged and the runner checks the flag between steps.
// Arcod cannot abort an in-flight io.remote or model call (#46), so the answer
// is honest about where the stop happens.
const CR_CANCELLED = 'cancelled';
const CR_FINAL = ['succeeded', 'failed', 'budget_exceeded', 'cancelled'];

export async function cancelRun(input, io) {
  const runId = typeof input === 'string' ? input : String((input && input.runId) || '');
  const run = await io.fetch('Run', runId);
  if (!run) return { error: 'NotFound' };
  if (CR_FINAL.indexOf(run.status) >= 0) return { error: 'Conflict' };

  if (run.status === 'queued') {
    const updated = await io.update('Run', runId, {
      status: CR_CANCELLED,
      cancelRequested: true,
      error: 'cancelled before the runner picked it up',
      finishedAt: new Date().toISOString(),
    });
    return { result: updated };
  }

  const updated = await io.update('Run', runId, { cancelRequested: true });
  return { result: updated };
}
