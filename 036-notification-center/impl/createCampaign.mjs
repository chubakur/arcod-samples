// The audience is written row by row before the campaign exists for the
// consumer: a restart after the HTTP answer still finds every address. The
// queue message carries only the campaign id.
export async function createCampaign(input, io) {
  const templateCode = String(input.templateCode || '').trim().toLowerCase();
  const name = String(input.name || '').trim();
  const audience = Array.isArray(input.audience) ? input.audience : [];
  if (!templateCode || !name) return { error: 'Invalid' };
  if (audience.length === 0 || audience.length > 200) return { error: 'Invalid' };

  const template = await io.find('Template', { where: { code: templateCode }, limit: 1 });
  if ((template.items || []).length === 0) return { error: 'NotFound' };

  const campaignId = await io.new();
  const seen = new Set();
  const rows = [];
  for (const recipient of audience) {
    const email = String(recipient.email || '').trim().toLowerCase();
    if (!email || seen.has(email)) continue;
    seen.add(email);
    const row = {
      id: await io.new(),
      campaignId,
      email,
      name: String(recipient.name || '').trim() || email.split('@')[0],
    };
    await io.insert('AudienceRow', row);
    rows.push(row);
  }
  if (rows.length === 0) return { error: 'Invalid' };

  const campaign = {
    id: campaignId,
    templateCode,
    name,
    audienceSize: rows.length,
    status: 'queued',
    createdAt: Date.now(),
    finishedAt: null,
  };
  await io.insert('Campaign', campaign);
  // The outbox carries this publish in the same transaction as the insert:
  // a crash between the two cannot lose the campaign.
  await io.queuePublish('fanout', { campaignId });
  return { result: campaign };
}
