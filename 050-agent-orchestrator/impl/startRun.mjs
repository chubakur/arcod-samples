// The request only enqueues. Everything expensive - model turn, tool call,
// trace - happens in the execute consumer, so the API stays a write and a
// publish. clientRef is the idempotency key; an empty one gets a server-side
// value, because the unique rule must hold for every row.
export async function startRun(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const agentId = String(body.agentId || '');
  const text = String(body.input || '').trim();
  if (!text) return { error: 'Invalid' };

  const agent = await io.fetch('Agent', agentId);
  if (!agent) return { error: 'NotFound' };

  const requested = String(body.clientRef || '').trim();
  if (requested) {
    const prior = await io.find('Run', { where: { clientRef: requested }, limit: 1 });
    const row = (prior.items || [])[0];
    if (row) return { result: row };
  }

  const run = {
    id: await io.new(),
    agentId,
    clientRef: requested || (await io.new()),
    input: text,
    status: 'queued',
    steps: 0,
    tokens: 0,
    toolCalls: 0,
    answer: '',
    error: '',
    cancelRequested: false,
    createdAt: new Date().toISOString(),
    startedAt: null,
    finishedAt: null,
    traceKey: '',
  };
  await io.insert('Run', run);
  await io.queuePublish('execute', run.id);
  return { result: run };
}
