// One message per recipient, one row per address. The audience lives in its own
// table, so a redelivery re-reads the same rows and the existing deliveries make
// the second pass a no-op.
export async function fanout(input, io) {
  const campaignId = String(input.campaignId || '');
  const campaign = await io.fetch('Campaign', campaignId);
  if (!campaign) return { ok: true, skipped: true };
  if (campaign.status !== 'queued') return { ok: true, skipped: true };

  const audience = await io.find('AudienceRow', { where: { campaignId }, limit: 500 });
  const existing = await io.find('Delivery', { where: { campaignId }, limit: 500 });
  const seen = new Set((existing.items || []).map((row) => String(row.email).toLowerCase()));
  const created = [];
  for (const recipient of audience.items || []) {
    const email = String(recipient.email || '').trim().toLowerCase();
    if (!email || seen.has(email)) continue;
    seen.add(email);
    const delivery = {
      id: await io.new(),
      campaignId,
      email,
      name: String(recipient.name || '').trim() || email.split('@')[0],
      status: 'queued',
      attempts: 0,
      error: null,
      sentAt: null,
    };
    await io.insert('Delivery', delivery);
    created.push(delivery.id);
  }

  await io.update('Campaign', campaignId, {
    audienceSize: seen.size,
    status: 'sending',
  });
  for (const deliveryId of created) {
    await io.queuePublish('deliver', { deliveryId });
  }
  return { ok: true, enqueued: created.length };
}
