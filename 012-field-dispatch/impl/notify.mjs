// Second consumer: customer notification through the SMS gateway.
export async function notify(input, io) {
  const id = String(input.ticketId || '');
  if (!id) return { result: false };

  const ticket = await io.fetch('Ticket', id);
  if (!ticket) return { result: false };

  await io.remote('Router', 'notify', {
    ticketId: id,
    code: ticket.code,
    message: 'Work ' + ticket.code + ' is closed: ' + String(ticket.note || ''),
  });
  return { result: true };
}
