// SLA by severity. The sweep is called by the external runner; arcod jobs are
// queue consumers, not cron tasks, so the trigger lives outside the contract.
const SLA_SECONDS = { SEV1: 300, SEV2: 900, SEV3: 3600, SEV4: 4 * 3600 };

export async function sweep(input, io) {
  const now = input.now ? Date.parse(String(input.now)) : Date.now();
  if (!Number.isFinite(now)) return { result: { breached: 0, escalated: 0 } };

  const page = await io.find('Incident', { where: { status: 'open' }, limit: 500 });
  let breached = 0;
  let escalated = 0;
  for (const row of page.items || []) {
    if (row.ackedAt || row.escalated) continue;
    const sla = (SLA_SECONDS[row.severity] || SLA_SECONDS.SEV2) * 1000;
    if (now - Date.parse(row.openedAt) < sla) continue;
    breached += 1;
    await io.update('Incident', row.id, { escalated: true });
    await io.insert('IncidentEvent', {
      id: await io.new(),
      incidentId: row.id,
      kind: 'escalated',
      actor: 'system',
      detail: 'SLA ' + sla / 1000 + 's missed without acknowledgement',
      at: new Date(now).toISOString()
    });
    await io.queuePublish('notify', row.id);
    escalated += 1;
  }
  return { result: { breached, escalated } };
}
