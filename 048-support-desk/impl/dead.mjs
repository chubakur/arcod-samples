// Dead letters per consumer. A non-empty list means a job exhausted its
// retries; smoke asserts it stays empty on the happy path.
export async function dead(input, io) {
  const rows = [];
  for (const topic of ['triage', 'notify', 'exportRun']) {
    const items = await io.queueDead(topic);
    for (const item of items || []) {
      const payload = item && item.payload ? item.payload : {};
      rows.push(topic + ' ' + String(payload.ticketId || payload.exportId || payload) + ' :: ' + String((item && item.lastError) || 'unknown'));
    }
  }
  return { result: rows };
}
