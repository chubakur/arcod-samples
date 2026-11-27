export async function dead(input, io) {
  const matchmakeRows = await io.queueDead('matchmake');
  const archiveRows = await io.queueDead('archive');
  const rows = [];
  for (const item of matchmakeRows || []) {
    const payload = item && item.payload ? item.payload : {};
    rows.push('matchmake ' + String(payload.ticketId || payload) + ' :: ' + String((item && item.lastError) || 'unknown'));
  }
  for (const item of archiveRows || []) {
    const payload = item && item.payload ? item.payload : {};
    rows.push('archive ' + String(payload.matchId || payload) + ' :: ' + String((item && item.lastError) || 'unknown'));
  }
  return { result: rows };
}
