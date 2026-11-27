// Consumer 2: one notification per (message, recipient). The id is derived from
// both, so redelivery is an insert conflict that is caught and skipped.
export async function notify(input, io) {
  const ticketId = typeof input === 'string' ? input : String((input && input.ticketId) || '');
  if (!ticketId) return { result: false };
  const ticket = await io.fetch('Ticket', ticketId);
  if (!ticket) return { result: false };

  let message = null;
  if (ticket.lastMessageId) message = await io.fetch('Message', ticket.lastMessageId);
  if (!message) {
    const page = await io.find('Message', { where: { ticketId }, order: 'createdAt desc', limit: 1 });
    message = (page.items || [])[0] || null;
  }
  if (!message) return { result: false };
  if (message.internal) return { result: true };

  const targets = [];
  if (message.author === ticket.requester) {
    if (ticket.assignee) targets.push(ticket.assignee);
    else {
      const page = await io.find('Member', { where: { tenantId: ticket.tenantId }, limit: 500 });
      for (const member of page.items || []) {
        if (member.role === 'owner' || member.role === 'agent') targets.push(member.userId);
      }
    }
  } else {
    targets.push(ticket.requester);
  }

  const now = new Date().toISOString();
  for (const userId of targets) {
    if (!userId || userId === message.author) continue;
    const id = 'nt:' + message.id + ':' + userId;
    const text = userId === ticket.requester
      ? 'Update on your ticket: ' + ticket.subject
      : 'New message on ticket: ' + ticket.subject;
    try {
      await io.insert('Notification', {
        id,
        tenantId: ticket.tenantId,
        ticketId,
        userId,
        kind: 'message',
        text,
        readAt: null,
        createdAt: now,
      });
    } catch (error) {
      if (!ntIsConflict(error)) throw error;
    }
  }
  return { result: true };
}

function ntIsConflict(error) {
  return Boolean(error) && (error.error === 'Conflict' || error.name === 'Conflict');
}
