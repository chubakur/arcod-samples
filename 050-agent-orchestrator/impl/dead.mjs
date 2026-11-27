export async function dead(_input, io) {
  const rows = await io.queueDead('execute');
  return { result: rows || [] };
}
