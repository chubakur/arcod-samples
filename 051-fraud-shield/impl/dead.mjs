export async function dead(_input, io) {
  const scoreRows = (await io.queueDead('score')) || [];
  const notifyRows = (await io.queueDead('notify')) || [];
  return { result: scoreRows.concat(notifyRows) };
}
