export async function dead(input, io) {
  const items = await io.queueDead('deliver');
  return {
    result: (items || []).map((item) => {
      const payload = item && item.payload ? item.payload : {};
      return String(payload.deliveryId || '') + ' :: ' + String((item && item.lastError) || 'unknown');
    }),
  };
}
