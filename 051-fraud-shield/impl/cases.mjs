export async function cases(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const status = String(body.status || 'open').trim();
  const limit = Math.min(Math.max(Number(body.limit || 50), 1), 200);
  const page = await io.find('Case', {
    where: status ? { status } : {},
    order: 'openedAt asc',
    limit,
  });
  return { result: page.items || [] };
}
