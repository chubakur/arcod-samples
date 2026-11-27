// A reply is a message plus a ticket update. Internal notes are staff-only.
// A customer reply on a resolved ticket reopens it; the customer decides when
// the problem is actually gone.
export async function reply(input, io) {
  const actor = await io.actor();
  const ticketId = String(input.ticketId || '');
  const body = String(input.body || '').trim();
  const internal = input.internal === true;

  const row = await io.fetch('Ticket', ticketId);
  if (!row) return { error: 'NotFound' };
  const member = await rpMember(io, row.tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };
  const staff = rpStaff(member);
  if (internal && !staff) return { error: 'Forbidden' };
  if (!body || body.length > 8000) return { error: 'Invalid' };

  const now = new Date().toISOString();
  const message = {
    id: await io.new(),
    ticketId,
    tenantId: row.tenantId,
    author: actor.id,
    authorName: actor.name,
    internal,
    body,
    createdAt: now,
  };
  await io.insert('Message', message);

  const next = {
    updatedAt: now,
    lastMessageId: message.id,
    messageCount: Number(row.messageCount || 0) + 1,
  };
  if (staff && !row.firstReplyAt) next.firstReplyAt = now;
  if (!staff && row.status === 'resolved') {
    next.status = 'open';
    next.resolvedAt = null;
  }
  await io.update('Ticket', ticketId, next);
  await io.insert('Audit', {
    id: await io.new(),
    tenantId: row.tenantId,
    ticketId,
    actor: actor.id,
    action: internal ? 'message.internal' : 'message.public',
    detail: body.slice(0, 120),
    at: now,
  });

  await io.queuePublish('notify', ticketId);
  return { result: message };
}

function rpStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function rpMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
