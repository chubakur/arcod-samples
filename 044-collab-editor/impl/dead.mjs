export async function dead(input, io) {
  const compact = await io.queueDead('compact');
  const notify = await io.queueDead('notify');
  const rows = [];
  for (const item of compact || []) {
    const payload = item && item.payload ? item.payload : {};
    rows.push('compact ' + String(payload.docId || '') + ' :: ' + String((item && item.lastError) || 'unknown'));
  }
  for (const item of notify || []) {
    const payload = item && item.payload ? item.payload : {};
    rows.push('notify ' + String(payload.commentId || '') + ' :: ' + String((item && item.lastError) || 'unknown'));
  }
  return { result: rows };
}
