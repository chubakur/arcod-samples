export async function attempts(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const status = String(body.status || '').trim();
  const limit = Math.min(Math.max(Number(body.limit || 50), 1), 200);
  const page = await io.find('Attempt', {
    where: status ? { status } : {},
    order: 'createdAt desc',
    limit,
  });
  return { result: page.items || [] };
}
