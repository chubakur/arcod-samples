export async function dead(input, io) {
  const topics = ['notify', 'postmortem'];
  const rows = [];
  for (const topic of topics) {
    const items = await io.queueDead(topic);
    for (const item of items || []) {
      const payload = item && item.payload ? item.payload : {};
      rows.push(topic + ' ' + String(payload.incidentId || payload) + ' :: ' + String((item && item.lastError) || 'unknown'));
    }
  }
  return { result: rows };
}
