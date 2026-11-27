// Consumer 1: assignment. Least-loaded staff member wins; a ticket already
// assigned is left alone. The audit row makes the automatic decision visible in
// the same trail as manual ones.
export async function triage(input, io) {
  const ticketId = typeof input === 'string' ? input : String((input && input.ticketId) || '');
  if (!ticketId) return { result: false };
  const ticket = await io.fetch('Ticket', ticketId);
  if (!ticket) return { result: false };

  if (!ticket.assignee) {
    const page = await io.find('Member', { where: { tenantId: ticket.tenantId }, limit: 500 });
    const staff = (page.items || []).filter((row) => row.role === 'owner' || row.role === 'agent');
    let best = null;
    let bestLoad = Number.MAX_SAFE_INTEGER;
    for (const member of staff) {
      const open = Number(await io.count('Ticket', {
        where: { tenantId: ticket.tenantId, assignee: member.userId, status: 'open' },
      })) || 0;
      const pending = Number(await io.count('Ticket', {
        where: { tenantId: ticket.tenantId, assignee: member.userId, status: 'pending' },
      })) || 0;
      const load = open + pending;
      if (load < bestLoad) {
        best = member;
        bestLoad = load;
      }
    }
    if (best) {
      const now = new Date().toISOString();
      await io.update('Ticket', ticketId, { assignee: best.userId, updatedAt: now });
      await io.insert('Audit', {
        id: await io.new(),
        tenantId: ticket.tenantId,
        ticketId,
        actor: 'system',
        action: 'ticket.triaged',
        detail: best.name + ' load ' + bestLoad,
        at: now,
      });
    }
  }

  await io.queuePublish('notify', ticketId);
  return { result: true };
}
