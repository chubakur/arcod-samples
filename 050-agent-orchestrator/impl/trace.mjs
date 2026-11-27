// The trace is written once, at the end, by the runner. A queued or running
// run has no key yet and answers NotFound rather than inventing a document.
export async function trace(input, io) {
  const runId = typeof input === 'string' ? input : String((input && input.runId) || '');
  const run = await io.fetch('Run', runId);
  if (!run || !run.traceKey) return { error: 'NotFound' };
  const body = await io.blobGet(run.traceKey);
  const content = body == null ? '' : String(body);
  return { result: { key: run.traceKey, content, bytes: content.length } };
}
