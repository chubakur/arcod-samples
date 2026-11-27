// SLA breach sweep. arcod jobs are consumers, not cron tasks (#12), so the
// runner calls this with an explicit instant. breachAlerted makes it idempotent:
// a second sweep for the same ticket writes nothing and returns 0.
export async function sweep(input, io) {
  const at = input.now ? Date.parse(String(input.now)) : Date.now();
  if (!Number.isFinite(at)) return { result: { breached: 0 } };

  let breached = 0;
  for (const status of ['open', 'pending']) {
    const page = await io.find('Ticket', { where: { status }, limit: 500 });
    for (const row of (page.items || []).filter((item) => item.status === status)) {
      if (row.breachAlerted) continue;
      const due = Date.parse(row.slaDueAt);
      if (!Number.isFinite(due) || due > at) continue;

      breached += 1;
      await io.update('Ticket', row.id, { breachAlerted: true });
      const now = new Date(at).toISOString();
      await io.insert('Audit', {
        id: await io.new(),
        tenantId: row.tenantId,
        ticketId: row.id,
        actor: 'system',
        action: 'sla.breached',
        detail: 'due ' + row.slaDueAt,
        at: now,
      });
      await io.insert('Notification', {
        id: await io.new(),
        tenantId: row.tenantId,
        ticketId: row.id,
        userId: row.assignee || row.requester,
        kind: 'breach',
        text: 'SLA breached: ' + row.subject,
        readAt: null,
        createdAt: now,
      });
    }
  }
  return { result: { breached } };
}
