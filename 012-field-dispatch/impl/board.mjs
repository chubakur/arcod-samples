export async function board(input, io) {
  const city = String(input.city || '').trim();
  const status = String(input.status || '').trim();

  const where = {};
  if (city) where.city = city;
  if (status) where.status = status;

  const found = await io.find('Ticket', { where, order: 'dueAt asc', limit: 100 });
  return { result: found.items || [] };
}
