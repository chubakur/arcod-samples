// Two upstreams for 050-agent-orchestrator, both on the host:
//   :9099  an OpenAI-compatible model that answers with one JSON object -
//          a tool call or a final answer, chosen from the task text;
//   :9098  the tool sandbox the agent is allowed to call.
// They are deterministic on purpose: the smoke test checks the orchestrator,
// not a model. Arcod reaches :9098 through an endpoint (localhost is rewritten
// to host.docker.internal) and :9099 through the llm binding's baseUrl.
import http from 'node:http';

const LLM_PORT = Number(process.env.LLM_PORT || 9099);
const TOOLS_PORT = Number(process.env.TOOLS_PORT || 9098);
const stats = { llmCalls: 0, toolCalls: 0 };

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch (error) { reject(error); }
    });
    req.on('error', reject);
  });
}

function lastObservation(messages) {
  const notes = messages.filter((m) => m.role === 'user' && typeof m.content === 'string' && m.content.startsWith('observation:'));
  return notes.length > 0 ? notes[notes.length - 1].content.slice('observation: '.length) : '';
}

function toolCall(name, args) {
  return { content: JSON.stringify({ tool: name, args }) };
}

function final(text) {
  return { content: JSON.stringify({ final: text }) };
}

// The task text is the first user message and never changes during a run, so
// the scenario survives a resume as well.
function answer(messages) {
  const first = messages.find((m) => m.role === 'user');
  const task = String((first && first.content) || '').toLowerCase();
  const observations = messages.filter((m) => m.role === 'user' && typeof m.content === 'string' && m.content.startsWith('observation:')).length;
  const observed = lastObservation(messages);

  if (task.includes('loop')) return toolCall('lookup_order', { orderId: '1042' });
  if (task.includes('banned')) return toolCall('drop_database', { confirm: 'yes' });
  if (task.includes('broken')) return toolCall('lookup_order', { orderId: '0000' });
  if (task.includes('slow')) {
    return observations === 0 ? toolCall('sleep', { ms: 1500 }) : final('The slow tool finished; nothing else to do.');
  }
  if (task.includes('refund')) {
    if (observations === 0) return toolCall('refund_order', { orderId: '1042', amount: 12900 });
    return final('Refund of 129.00 RUB for order 1042 is accepted: ' + observed);
  }
  if (task.includes('1042')) {
    if (observations === 0) return toolCall('lookup_order', { orderId: '1042' });
    let parsed = {};
    try { parsed = JSON.parse(observed); } catch (error) { parsed = {}; }
    return final('Order ' + (parsed.orderId || '1042') + ' is ' + (parsed.status || 'unknown') +
      '; total ' + (Number(parsed.total || 0) / 100).toFixed(2) + ' ' + (parsed.currency || 'RUB') + '.');
  }
  return final('Echo: ' + String((first && first.content) || '').slice(0, 120));
}

const llm = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/stats') return json(res, 200, stats);
  if (req.method !== 'POST' || req.url !== '/v1/chat/completions') return json(res, 404, { error: 'not found' });
  let body;
  try { body = await readBody(req); } catch (error) { return json(res, 400, { error: 'bad json' }); }
  const messages = Array.isArray(body.messages) ? body.messages : [];
  stats.llmCalls += 1;
  const reply = answer(messages);
  return json(res, 200, {
    id: 'chatcmpl-mock-' + stats.llmCalls,
    object: 'chat.completion',
    model: body.model || 'arcod-mock',
    choices: [{ index: 0, message: { role: 'assistant', content: reply.content }, finish_reason: 'stop' }],
    usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
  });
});

const tools = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/stats') return json(res, 200, stats);
  if (req.method === 'GET' && req.url === '/healthz') return json(res, 200, { ok: true });
  if (req.method !== 'POST' || req.url !== '/v1/tools/call') return json(res, 404, { ok: false, output: 'not found' });
  let body;
  try { body = await readBody(req); } catch (error) { return json(res, 400, { ok: false, output: 'bad json' }); }
  stats.toolCalls += 1;
  const name = String(body.name || '');
  let args = {};
  try { args = JSON.parse(String(body.args || '{}')); } catch (error) { args = {}; }

  if (name === 'lookup_order') {
    if (String(args.orderId) === '0000') return json(res, 502, { ok: false, output: 'order service is down' });
    return json(res, 200, { ok: true, output: JSON.stringify({ orderId: String(args.orderId || ''), status: 'shipped', total: 12900, currency: 'RUB' }) });
  }
  if (name === 'refund_order') {
    return json(res, 200, { ok: true, output: JSON.stringify({ orderId: String(args.orderId || ''), refunded: true, amount: Number(args.amount || 0), currency: 'RUB' }) });
  }
  if (name === 'sleep') {
    const ms = Math.min(Math.max(Number(args.ms || 500), 0), 5000);
    await new Promise((resolve) => setTimeout(resolve, ms));
    return json(res, 200, { ok: true, output: JSON.stringify({ slept: ms }) });
  }
  return json(res, 404, { ok: false, output: 'unknown tool: ' + name });
});

llm.listen(LLM_PORT, '0.0.0.0', () => console.log('mock llm on ' + LLM_PORT));
tools.listen(TOOLS_PORT, '0.0.0.0', () => console.log('mock tools on ' + TOOLS_PORT));
