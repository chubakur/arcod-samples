export async function campaign(input, io) {
  const campaign = await io.fetch('Campaign', String(input.id || ''));
  if (!campaign) return { error: 'NotFound' };
  const sent = await io.count('Delivery', { where: { campaignId: campaign.id, status: 'sent' } });
  const failed = await io.count('Delivery', { where: { campaignId: campaign.id, status: 'failed' } });
  const queued = await io.count('Delivery', { where: { campaignId: campaign.id, status: 'queued' } });
  const retrying = await io.count('Delivery', { where: { campaignId: campaign.id, status: 'retrying' } });
  const total = await io.count('Delivery', { where: { campaignId: campaign.id } });
  return {
    result: {
      campaign,
      total,
      sent,
      failed,
      queued: queued + retrying,
    },
  };
}
