// Nothing in the queue survives a lost consumer, but the row does. The sweep
// is the only thing that looks at age: erasing for over five minutes, or erased
// with no certificate after two, is stuck by definition.
function ageMs(stamp, now) {
  const at = Date.parse(String(stamp || ''));
  if (!Number.isFinite(at)) return Number.MAX_SAFE_INTEGER;
  return now - at;
}

export async function sweep(input, io) {
  const now = Date.now();
  let queued = 0;

  const erasing = await io.find('ErasureRequest', { where: { state: 'erasing' }, limit: 500 });
  for (const row of (erasing && erasing.items) || []) {
    if (ageMs(row.updatedAt, now) < 5 * 60 * 1000) continue;
    await io.queuePublish('erase', { requestId: row.id });
    queued += 1;
  }

  const erased = await io.find('ErasureRequest', { where: { state: 'erased' }, limit: 500 });
  for (const row of (erased && erased.items) || []) {
    if (ageMs(row.updatedAt, now) < 2 * 60 * 1000) continue;
    await io.queuePublish('erased', { requestId: row.id });
    queued += 1;
  }

  return { result: { ok: true, queued } };
}
