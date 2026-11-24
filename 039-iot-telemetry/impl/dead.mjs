function asText(item) {
  return typeof item === 'string' ? item : JSON.stringify(item);
}

export async function dead(input, io) {
  const samples = await io.queueDead('samples');
  const reports = await io.queueDead('reports');
  const items = [...(samples || []), ...(reports || [])].map(asText);
  return { result: { items } };
}
