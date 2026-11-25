export async function zones(input, io) {
  const found = await io.find('Zone', { limit: 200 });
  return { result: found.items || [] };
}
