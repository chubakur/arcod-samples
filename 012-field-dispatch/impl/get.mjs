export async function get(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };

  const ticket = await io.fetch('Ticket', id);
  if (!ticket) return { error: 'NotFound' };
  return { result: ticket };
}
