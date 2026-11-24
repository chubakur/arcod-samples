export async function deliveries(input, io) {
  const campaignId = String(input.id || '');
  const page = await io.find('Delivery', { where: { campaignId }, limit: 200 });
  return {
    result: {
      items: page.items || [],
      total: await io.count('Delivery', { where: { campaignId } }),
    },
  };
}
