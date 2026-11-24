// The operator pastes the line /v1/dead printed. A dead entry is the envelope
// {payload, attempts, lastError}; the driver compares against the carried
// payload, so the envelope is unwrapped first.
export async function dropDead(input, io) {
  const text = String(input.payload || '');
  if (!text) return { result: { dropped: false } };

  let payload = text;
  try {
    const parsed = JSON.parse(text);
    payload = parsed && typeof parsed === 'object' && parsed.payload !== undefined ? parsed.payload : parsed;
  } catch {
    payload = text;
  }

  const samples = await io.queueDeadDrop('samples', payload);
  const reports = samples ? false : await io.queueDeadDrop('reports', payload);
  return { result: { dropped: Boolean(samples || reports) } };
}
