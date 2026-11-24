export async function dead(input, io) {
  const items = await io.queueDead('execute');
  return {
    result: items.map((item) => {
      const payload = item && item.payload ? item.payload : {};
      return String(payload.runId || '') + ' :: ' + String((item && item.lastError) || 'unknown');
    }),
  };
}
