export async function fanoutAgain(input, io) {
  const id = String(input.id || '');
  const campaign = await io.fetch('Campaign', id);
  if (!campaign) return { error: 'NotFound' };
  await io.queuePublish('fanout', { campaignId: id });
  return { result: { ok: true, enqueued: 1 } };
}
