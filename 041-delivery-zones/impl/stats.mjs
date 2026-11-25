export async function stats(input, io) {
  const zones = await io.count('Zone');
  const quotes = await io.count('Quote');
  const active = await io.find('Zone', { where: { active: true }, limit: 200 });
  return {
    result: {
      zones,
      quotes,
      activeZones: (active.items || []).length,
    },
  };
}
