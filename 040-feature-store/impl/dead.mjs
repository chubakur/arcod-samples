function asText(item) {
  return typeof item === 'string' ? item : JSON.stringify(item);
}

export async function dead(input, io) {
  const events = await io.queueDead('events');
  const exports = await io.queueDead('exports');
  const items = [...(events || []), ...(exports || [])].map(asText);
  return { result: { items } };
}
