// A new agent is a prompt and a closed tool list. The name is the natural key:
// a second registration of the same name is a conflict, not a silent update.
export async function createAgent(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const name = String(body.name || '').trim();
  const prompt = String(body.systemPrompt || '').trim();
  if (!name || !prompt) return { error: 'Invalid' };

  const existing = await io.find('Agent', { where: { name }, limit: 1 });
  if ((existing.items || []).length > 0) return { error: 'Conflict' };

  const agent = {
    id: await io.new(),
    name,
    systemPrompt: prompt,
    tools: String(body.tools || '').trim(),
    maxSteps: Number(body.maxSteps || 6),
    tokenBudget: Number(body.tokenBudget || 8000),
    pricePer1kTokens: Number(body.pricePer1kTokens == null ? 10 : body.pricePer1kTokens),
    pricePerToolCall: Number(body.pricePerToolCall == null ? 2 : body.pricePerToolCall),
    createdAt: new Date().toISOString(),
  };
  await io.insert('Agent', agent);
  return { result: agent };
}
