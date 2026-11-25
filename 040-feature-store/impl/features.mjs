export async function features(input, io) {
  const found = await io.find('Feature', { limit: 500 });
  const items = (found.items || []).slice().sort((a, b) => String(a.name).localeCompare(String(b.name)));
  return { result: items };
}
