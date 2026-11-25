function unwrap(item) {
  const text = typeof item === 'string' ? item : JSON.stringify(item);
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { text, payload: text };
  }
  const payload = parsed && typeof parsed === 'object' && parsed.payload !== undefined ? parsed.payload : parsed;
  return { text, payload };
}

export async function replayDead(input, io) {
  let replayed = 0;
  for (const topic of ['events', 'exports']) {
    const items = await io.queueDead(topic);
    for (const item of items || []) {
      const { text, payload } = unwrap(item);
      const ok = await io.queueDeadDrop(topic, payload);
      if (!ok) continue;
      await io.queuePublish(topic, payload);
      replayed += 1;
    }
  }
  const left = [...(await io.queueDead('events') || []), ...(await io.queueDead('exports') || [])].length;
  return { result: { replayed, left } };
}
