// Consumer 1: the agent loop. One model turn per iteration; a turn either
// names a tool or ends the run. Every turn is a durable Step row before the
// next call, so a redelivered message rebuilds the conversation from the
// transcript instead of starting over (or losing the work already done).
const EX_FINAL = ['succeeded', 'failed', 'budget_exceeded', 'cancelled'];
const EX_PROTOCOL = [
  'You are a tool-using agent.',
  'Answer with a single JSON object and nothing else.',
  'To use a tool reply {"tool":"<name>","args":{...}}.',
  'To finish reply {"final":"<answer>"}.',
].join(' ');

function exTokens(text) {
  const value = String(text == null ? '' : text);
  return Math.max(1, Math.ceil(value.length / 4));
}

function exParse(content) {
  let text = String(content || '').trim();
  if (text.startsWith('```')) {
    text = text.replace(/^```[a-z]*\n?/i, '').replace(/```$/, '').trim();
  }
  if (!text.startsWith('{')) return null;
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  if (typeof value.tool === 'string' && value.tool) {
    return { tool: value.tool, args: value.args && typeof value.args === 'object' ? value.args : {} };
  }
  return null;
}

function exFinalText(content) {
  const text = String(content || '').trim();
  if (!text.startsWith('{')) return text;
  try {
    const value = JSON.parse(text.replace(/^```[a-z]*\n?/i, '').replace(/```$/, '').trim());
    if (value && typeof value.final === 'string') return value.final;
  } catch (error) {
    return text;
  }
  return text;
}

// The transcript is the source of truth for a resume: the input plus every
// recorded tool turn, with the observation the tool returned.
function exRebuild(input, steps) {
  const messages = [{ role: 'user', content: String(input || '') }];
  for (const step of steps) {
    if (step.kind !== 'tool') continue;
    messages.push({ role: 'assistant', content: JSON.stringify({ tool: step.tool, args: JSON.parse(step.args || '{}') }) });
    messages.push({ role: 'user', content: 'observation: ' + step.output });
  }
  return messages;
}

async function exFinish(io, run, patch, messages) {
  const finishedAt = new Date().toISOString();
  const traceKey = 'runs/' + run.id + '.json';
  const trace = {
    runId: run.id,
    agentId: run.agentId,
    status: patch.status,
    answer: patch.answer || '',
    error: patch.error || '',
    tokens: patch.tokens,
    toolCalls: patch.toolCalls,
    steps: patch.steps,
    messages,
    finishedAt,
  };
  await io.blobPut(traceKey, JSON.stringify(trace, null, 2), 'application/json');
  await io.update('Run', run.id, {
    status: patch.status,
    answer: patch.answer || '',
    error: patch.error || '',
    tokens: patch.tokens,
    toolCalls: patch.toolCalls,
    steps: patch.steps,
    finishedAt,
    traceKey,
  });
  await io.queuePublish('finished', run.id);
}

export async function execute(input, io) {
  const runId = typeof input === 'string' ? input : String((input && input.runId) || '');
  if (!runId) return { result: false };
  const run = await io.fetch('Run', runId);
  if (!run) return { result: false };
  if (EX_FINAL.indexOf(run.status) >= 0) return { result: true };

  const agent = await io.fetch('Agent', run.agentId);
  if (!agent) {
    await exFinish(io, run, { status: 'failed', error: 'agent missing: ' + run.agentId, tokens: 0, toolCalls: 0, steps: 0 }, []);
    return { result: true };
  }
  if (run.cancelRequested && run.status === 'queued') {
    await exFinish(io, run, { status: 'cancelled', error: 'cancelled before the first step', tokens: 0, toolCalls: 0, steps: 0 }, []);
    return { result: true };
  }

  const allowed = String(agent.tools || '')
    .split(',')
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
  const system = String(agent.systemPrompt || '') + '\n' + EX_PROTOCOL;
  const stepPage = await io.find('Step', { where: { runId }, order: 'seq asc', limit: 200 });
  const steps = stepPage.items || [];
  const messages = exRebuild(run.input, steps);

  let tokens = Number(run.tokens || 0);
  let toolCalls = Number(run.toolCalls || 0);
  let seq = steps.length;
  let status = 'succeeded';
  let answer = '';
  let failure = '';
  const maxSteps = Number(agent.maxSteps || 6);
  const budget = Number(agent.tokenBudget || 8000);

  if (run.status === 'queued') {
    await io.update('Run', runId, { status: 'running', startedAt: new Date().toISOString() });
  }

  for (let index = steps.length; index < maxSteps; index += 1) {
    const fresh = await io.fetch('Run', runId);
    if (fresh && fresh.cancelRequested) {
      status = 'cancelled';
      failure = 'cancelled by operator';
      break;
    }

    const promptTokens = exTokens(system) + exTokens(JSON.stringify(messages));
    let reply;
    try {
      reply = await io.chat(messages, system);
    } catch (error) {
      status = 'failed';
      failure = 'model: ' + String(error && error.message ? error.message : error);
      break;
    }
    const content = String((reply && reply.content) || '');
    const turnTokens = promptTokens + exTokens(content);
    tokens += turnTokens;
    seq += 1;
    const at = new Date().toISOString();

    const call = exParse(content);
    if (!call) {
      answer = exFinalText(content);
      await io.insert('Step', {
        id: await io.new(), runId, seq, kind: 'final', tool: '', args: '', output: content, tokens: turnTokens, at,
      });
      break;
    }

    if (allowed.indexOf(call.tool) < 0) {
      await io.insert('Step', {
        id: await io.new(), runId, seq, kind: 'denied', tool: call.tool,
        args: JSON.stringify(call.args), output: 'tool is not in the agent allow-list', tokens: turnTokens, at,
      });
      status = 'failed';
      failure = 'tool not allowed: ' + call.tool;
      break;
    }

    let observation;
    try {
      const response = await io.remote('Tools', 'call', { name: call.tool, args: JSON.stringify(call.args) });
      const body = response && response.body ? response.body : response;
      const ok = response && response.status >= 200 && response.status < 300 && body && body.ok === true;
      if (!ok) {
        await io.insert('Step', {
          id: await io.new(), runId, seq, kind: 'error', tool: call.tool,
          args: JSON.stringify(call.args), output: JSON.stringify(body || {}), tokens: turnTokens, at,
        });
        status = 'failed';
        failure = 'tool ' + call.tool + ' failed: ' + String((body && body.output) || ('status ' + (response && response.status)));
        break;
      }
      observation = String(body.output == null ? '' : body.output);
    } catch (error) {
      await io.insert('Step', {
        id: await io.new(), runId, seq, kind: 'error', tool: call.tool,
        args: JSON.stringify(call.args), output: String(error && error.message ? error.message : error), tokens: turnTokens, at,
      });
      status = 'failed';
      failure = 'tool ' + call.tool + ' unreachable: ' + String(error && error.message ? error.message : error);
      break;
    }

    toolCalls += 1;
    await io.insert('Step', {
      id: await io.new(), runId, seq, kind: 'tool', tool: call.tool,
      args: JSON.stringify(call.args), output: observation, tokens: turnTokens, at,
    });
    await io.update('Run', runId, { tokens, toolCalls, steps: seq });
    messages.push({ role: 'assistant', content });
    messages.push({ role: 'user', content: 'observation: ' + observation });

    if (tokens >= budget) {
      status = 'budget_exceeded';
      failure = 'token budget exceeded: ' + tokens + ' >= ' + budget;
      break;
    }
  }

  if (status === 'succeeded' && !answer && seq >= maxSteps) {
    status = 'failed';
    failure = 'step limit reached: ' + maxSteps;
  }

  const fresh = await io.fetch('Run', runId);
  if (fresh && fresh.cancelRequested && status !== 'failed') {
    status = 'cancelled';
    failure = failure || 'cancelled by operator';
  }

  await exFinish(io, run, { status, answer, error: failure, tokens, toolCalls, steps: seq }, messages);
  return { result: true };
}
