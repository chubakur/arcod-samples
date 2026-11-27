// The detail view: ticket, public thread, attachments. Internal notes are
// dropped for anyone who is not staff, and a requester may not open someone
// else's ticket even inside the same tenant.
export async function ticket(input, io) {
  const actor = await io.actor();
  const ticketId = String(input.ticketId || '');
  const row = await io.fetch('Ticket', ticketId);
  if (!row) return { error: 'NotFound' };

  const member = await tkMember(io, row.tenantId, actor.id);
  if (!member) return { error: 'Forbidden' };
  const staff = tkStaff(member);
  if (!staff && row.requester !== actor.id) return { error: 'Forbidden' };

  const messages = await io.find('Message', {
    where: { ticketId },
    order: 'createdAt asc',
    limit: 500,
  });
  const visible = [];
  for (const message of messages.items || []) {
    if (message.internal && !staff) continue;
    visible.push(message);
  }
  const attachments = await io.find('Attachment', {
    where: { ticketId },
    order: 'createdAt asc',
    limit: 200,
  });
  return {
    result: {
      ticket: row,
      messages: visible,
      attachments: attachments.items || [],
    },
  };
}

function tkStaff(member) {
  return member.role === 'owner' || member.role === 'agent';
}

async function tkMember(io, tenantId, userId) {
  const page = await io.find('Member', { where: { tenantId, userId }, limit: 1 });
  return (page.items || [])[0] || null;
}
