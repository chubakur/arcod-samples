export async function devices(input, io) {
  const found = await io.find('Device', { limit: 200 });
  const items = (found.items || []).slice().sort((a, b) => String(a.name).localeCompare(String(b.name)));
  return { result: items };
}
