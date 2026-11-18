export async function stats(input, io) {
  const page = await io.find('Event', { limit: 500 });
  const items = page.items || [];
  const out = { received: items.length, pending: 0, retrying: 0, delivered: 0, dead: 0 };
  for (const item of items) {
    const status = String(item.status || '');
    if (status in out && status !== 'received') out[status] += 1;
  }
  return { result: out };
}
