// The retry budget is 2, so a message that keeps failing is attempted three
// times before the queue moves it to the dead letter. The row records every
// attempt; the campaign is done when nothing is left queued or retrying.
const MAX_ATTEMPTS = 3;

function render(text, delivery, campaign) {
  return String(text)
    .split('{{name}}').join(delivery.name)
    .split('{{email}}').join(String(delivery.email))
    .split('{{campaign}}').join(campaign.name);
}

export async function deliver(input, io) {
  const deliveryId = String(input.deliveryId || '');
  const delivery = await io.fetch('Delivery', deliveryId);
  if (!delivery) return { ok: true, skipped: true };
  if (delivery.status === 'sent') return { ok: true, skipped: true };

  const campaign = await io.fetch('Campaign', String(delivery.campaignId));
  if (!campaign) return { ok: true, skipped: true };
  const found = await io.find('Template', { where: { code: campaign.templateCode }, limit: 1 });
  const template = (found.items || [])[0];
  const attempts = Number(delivery.attempts || 0) + 1;

  try {
    if (!template) throw new Error('template ' + campaign.templateCode + ' is gone');
    const reply = await io.remote('Mailer', 'send', {
      from: 'campaigns@arcod.test',
      to: delivery.email,
      subject: render(template.subject, delivery, campaign),
      text: render(template.body, delivery, campaign),
    });
    if (!reply || Number(reply.status) >= 400) {
      throw new Error('mailer answered ' + (reply ? reply.status : 'nothing'));
    }

    const now = Math.floor(Date.now() / 1000);
    if (delivery.status !== 'sent') {
      await io.update('Delivery', deliveryId, { status: 'sent', attempts, error: null, sentAt: now });
      await bump(io, campaign.templateCode, 'sent');
    }
  } catch (error) {
    const message = String((error && error.message) || error).slice(0, 200);
    const final = attempts >= MAX_ATTEMPTS;
    await io.update('Delivery', deliveryId, {
      status: final ? 'failed' : 'retrying',
      attempts,
      error: message,
    });
    if (final) await bump(io, campaign.templateCode, 'failed');
    // Throwing is what makes the runtime requeue; the dead letter is the
    // runtime's answer to the third failure, not the body's.
    throw error;
  }

  const left = await io.count('Delivery', { where: { campaignId: delivery.campaignId, status: 'queued' } })
    + await io.count('Delivery', { where: { campaignId: delivery.campaignId, status: 'retrying' } });
  if (left === 0 && campaign.status !== 'done') {
    await io.update('Campaign', String(delivery.campaignId), {
      status: 'done',
      finishedAt: Math.floor(Date.now() / 1000),
    });
  }
  return { ok: true, attempts };
}

// One row per day and template: the dashboard reads four numbers, not a scan
// over every delivery ever sent.
async function bump(io, templateCode, field) {
  const day = new Date().toISOString().slice(0, 10);
  const id = day + ':' + templateCode;
  const found = await io.fetch('DayStat', id);
  if (!found) {
    await io.insert('DayStat', {
      id,
      day,
      templateCode,
      sent: field === 'sent' ? 1 : 0,
      failed: field === 'failed' ? 1 : 0,
    });
    return;
  }
  await io.update('DayStat', id, {
    sent: Number(found.sent || 0) + (field === 'sent' ? 1 : 0),
    failed: Number(found.failed || 0) + (field === 'failed' ? 1 : 0),
  });
}
