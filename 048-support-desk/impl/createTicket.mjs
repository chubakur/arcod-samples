// One insert, one initial message, one queue event. The requester never waits
// for assignment or notification: those are consumer work.
const HIGH = ['down', 'urgent', 'critical', 'asap', 'blocker', 'outage'];
const SLA_MS = { high: 4 * 3600 * 1000, normal: 24 * 3600 * 1000, low: 72 * 3600 * 1000 };

export async function createTicket(input, io) {
  const actor = await io.actor();
  const tenantId = String(input.tenantId || '');
  const subject = String(input.subject || '').trim();
  const body = String(input.body || '').trim();

  if (!tenantId) return { error: 'NotFound' };
  const member = await ctMember(io, tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };
  const tenant = await io.fetch('Tenant', tenantId);
  if (!tenant) return { error: 'NotFound' };

  if (!subject || subject.length > 160) return { error: 'Invalid' };
  if (!body || body.length > 8000) return { error: 'Invalid' };

  const open = Number(await io.count('Ticket', { where: { tenantId, status: 'open' } })) || 0;
  const pending = Number(await io.count('Ticket', { where: { tenantId, status: 'pending' } })) || 0;
  if (open + pending >= Number(tenant.openLimit || 20)) return { error: 'Conflict' };

  const haystack = (subject + ' ' + body).toLowerCase();
  const priority = HIGH.some((word) => haystack.includes(word)) ? 'high' : 'normal';
  const now = Date.now();
  const ticketId = await io.new();
  const messageId = await io.new();

  const ticket = {
    id: ticketId,
    tenantId,
    requester: actor.id,
    requesterName: actor.name,
    assignee: '',
    subject,
    body,
    status: 'open',
    priority,
    slaDueAt: new Date(now + SLA_MS[priority]).toISOString(),
    createdAt: new Date(now).toISOString(),
    updatedAt: new Date(now).toISOString(),
    resolvedAt: null,
    firstReplyAt: null,
    breachAlerted: false,
    messageCount: 1,
    attachmentCount: 0,
    lastMessageId: messageId,
  };
  await io.insert('Ticket', ticket);
  await io.insert('Message', {
    id: messageId,
    ticketId,
    tenantId,
    author: actor.id,
    authorName: actor.name,
    internal: false,
    body,
    createdAt: ticket.createdAt,
  });
  await io.insert('Audit', {
    id: await io.new(),
    tenantId,
    ticketId,
    actor: actor.id,
    action: 'ticket.created',
    detail: priority,
    at: ticket.createdAt,
  });

  await io.queuePublish('triage', ticketId);
  return { result: ticket };
}

async function ctMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
