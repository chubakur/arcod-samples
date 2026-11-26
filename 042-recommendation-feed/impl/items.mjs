export async function items(input, io) {
  const page = await io.find('Item', { limit: 500 });
  const rows = (page.items || []).slice().sort((a, b) => String(a.title).localeCompare(String(b.title)));
  return { result: rows };
}
