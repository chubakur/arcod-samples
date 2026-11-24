// The job is the only writer of step results. Every step row is updated before
// the next one starts, so a crash and a queue retry resume from the last
// unfinished position instead of running the whole pipeline twice.
const TERMINAL = ['succeeded', 'failed', 'cancelled'];

async function artifactDigest(text) {
  const bytes = new TextEncoder().encode(String(text));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function safeName(name, position) {
  const base = String(name || 'artifact').toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  return (base || 'artifact') + '-' + position;
}

function logBody(step, reply, errorText) {
  const lines = [];
  lines.push('$ ' + step.command);
  if (reply) {
    lines.push('[stdout]');
    lines.push(String(reply.stdout == null ? '' : reply.stdout));
    lines.push('[stderr]');
    lines.push(String(reply.stderr == null ? '' : reply.stderr));
    lines.push('exit=' + String(reply.exitCode) + ' durationMs=' + String(reply.durationMs == null ? 0 : reply.durationMs));
  } else {
    lines.push('[runner error]');
    lines.push(String(errorText || 'runner did not answer'));
  }
  return lines.join('\n') + '\n';
}

async function skipRemaining(io, steps, afterPosition) {
  for (const step of steps) {
    if (Number(step.position) <= Number(afterPosition)) continue;
    if (step.status === 'succeeded' || step.status === 'skipped') continue;
    await io.update('StepRun', step.id, { status: 'skipped', finishedAt: Date.now() });
  }
}

export async function execute(input, io) {
  const runId = String(input.runId || '');
  let run = await io.fetch('Run', runId);
  if (!run) return { ok: true, skipped: 'run is gone' };
  if (TERMINAL.indexOf(String(run.status)) >= 0) return { ok: true, skipped: run.status };

  const defs = await io.find('StepRun', { where: { runId }, order: 'position asc', limit: 50 });
  const steps = defs.items || [];
  const now = Date.now();

  if (run.cancelRequested) {
    for (const step of steps) {
      if (step.status !== 'succeeded') await io.update('StepRun', step.id, { status: 'cancelled', finishedAt: now });
    }
    await io.update('Run', runId, { status: 'cancelled', finishedAt: now, error: 'cancelled before start' });
    return { ok: true, cancelled: true };
  }

  await io.update('Run', runId, {
    status: 'running',
    startedAt: run.startedAt || now,
    attempt: Number(run.attempt || 0) + 1,
  });

  let failure = null;
  let failurePosition = 0;

  for (const step of steps) {
    if (step.status === 'succeeded' || step.status === 'skipped' || step.status === 'cancelled') continue;

    run = await io.fetch('Run', runId);
    if (!run || run.cancelRequested) {
      await io.update('StepRun', step.id, { status: 'cancelled', finishedAt: Date.now() });
      await skipRemaining(io, steps, step.position);
      await io.update('Run', runId, { status: 'cancelled', finishedAt: Date.now(), error: 'cancelled by client' });
      return { ok: true, cancelled: true };
    }

    await io.update('StepRun', step.id, { status: 'running', startedAt: Date.now() });

    let reply = null;
    let runnerError = null;
    try {
      // An external call answers { status, body }: the body is the runner's
      // JSON, the status is the transport's. A 5xx is a failed step, not a
      // missing field.
      const answer = await io.remote('Runner', 'execute', {
        command: step.command,
        timeoutSec: Number(step.timeoutSec || 300),
      });
      if (!answer || Number(answer.status) >= 400) {
        runnerError = 'runner answered ' + String(answer && answer.status);
      } else {
        reply = answer.body == null ? answer : answer.body;
      }
    } catch (error) {
      runnerError = String((error && error.message) || error).slice(0, 300);
    }

    const exitCode = reply ? Number(reply.exitCode) : 1;
    const logKey = 'logs/' + runId + '/' + step.position + '.log';
    await io.blobPut(logKey, logBody(step, reply, runnerError), 'text/plain; charset=utf-8');

    let artifactCount = 0;
    if (reply && Array.isArray(reply.artifacts)) {
      for (const item of reply.artifacts) {
        const body = String((item && item.content) || '');
        const name = safeName(item && item.name, step.position);
        const key = 'artifacts/' + runId + '/' + name;
        await io.blobPut(key, body, 'text/plain; charset=utf-8');
        await io.insert('Artifact', {
          id: await io.new(),
          runId,
          stepPosition: step.position,
          name,
          key,
          bytes: new TextEncoder().encode(body).length,
          sha256: await artifactDigest(body),
          createdAt: Date.now(),
        });
        artifactCount += 1;
      }
    }

    const stepStatus = runnerError ? 'failed' : (exitCode === 0 ? 'succeeded' : 'failed');
    await io.update('StepRun', step.id, {
      status: stepStatus,
      exitCode,
      logKey,
      artifactCount,
      finishedAt: Date.now(),
    });

    if (stepStatus === 'failed') {
      failure = runnerError ? ('runner: ' + runnerError) : ('step ' + step.name + ' exited ' + exitCode);
      failurePosition = Number(step.position);
      break;
    }
  }

  if (!failure) {
    run = await io.fetch('Run', runId);
    if (run && run.cancelRequested) {
      await io.update('Run', runId, { status: 'cancelled', finishedAt: Date.now(), error: 'cancelled by client' });
      return { ok: true, cancelled: true };
    }
  }

  if (failure) {
    await skipRemaining(io, steps, failurePosition);
    await io.update('Run', runId, { status: 'failed', finishedAt: Date.now(), error: failure.slice(0, 300) });
    return { ok: false, failed: failure };
  }

  await io.update('Run', runId, { status: 'succeeded', finishedAt: Date.now(), error: null });
  return { ok: true, succeeded: true };
}
