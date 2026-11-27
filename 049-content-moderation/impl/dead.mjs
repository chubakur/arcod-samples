// Dead letters per consumer. A non-empty list means a job exhausted its retries.
export async function dead(input, io) {
  const rows = [];
  for (const topic of ['screen', 'notify', 'rescreen']) {
    const items = await io.queueDead(topic);
    for (const item of items || []) {
      const payload = item && item.payload ? item.payload : {};
      rows.push(topic + ' ' + String(payload.itemId || payload.policyId || payload) + ' :: ' + String((item && item.lastError) || 'unknown'));
    }
  }
  return { result: rows };
}
