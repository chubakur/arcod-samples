export async function rules(input, io) {
  const found = await io.find('Rule', { limit: 500 });
  const items = (found.items || []).slice().sort((a, b) => String(a.metric).localeCompare(String(b.metric)));
  return { result: items };
}
