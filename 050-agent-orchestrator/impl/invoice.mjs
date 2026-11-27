// Consumer 2: bill one finished run. The receipt in object storage is the
// artefact an operator can audit; the Usage row is what the API sums. Both are
// keyed by runId, so a redelivery after a partial write bills nothing twice.
export async function invoice(input, io) {
  const runId = typeof input === 'string' ? input : String((input && input.runId) || '');
  if (!runId) return { result: false };
  const run = await io.fetch('Run', runId);
  if (!run) return { result: false };
  if (['succeeded', 'failed', 'budget_exceeded', 'cancelled'].indexOf(run.status) < 0) {
    return { result: false };
  }

  const prior = await io.find('Usage', { where: { runId }, limit: 1 });
  if ((prior.items || []).length > 0) return { result: true };

  const agent = await io.fetch('Agent', run.agentId);
  const tokens = Number(run.tokens || 0);
  const toolCalls = Number(run.toolCalls || 0);
  const perK = agent ? Number(agent.pricePer1kTokens || 0) : 0;
  const perCall = agent ? Number(agent.pricePerToolCall || 0) : 0;
  const amount = Math.ceil((tokens * perK) / 1000) + toolCalls * perCall;
  const createdAt = new Date().toISOString();
  const receiptKey = 'billing/' + runId + '.json';

  await io.blobPut(receiptKey, JSON.stringify({
    runId,
    agentId: run.agentId,
    agentName: agent ? agent.name : '',
    status: run.status,
    tokens,
    toolCalls,
    pricePer1kTokens: perK,
    pricePerToolCall: perCall,
    amount,
    billedAt: createdAt,
  }, null, 2), 'application/json');

  await io.insert('Usage', {
    id: await io.new(),
    runId,
    agentId: run.agentId,
    tokens,
    toolCalls,
    amount,
    receiptKey,
    createdAt,
  });
  return { result: true };
}
