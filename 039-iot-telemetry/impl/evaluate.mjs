// One sample, every matching rule: device-specific rows and the site-wide "*"
// rows. The cooldown lives on the rule so a flapping sensor does not open a
// new alert on every sample.
const EVAL_OPS = { gt: (v, t) => v > t, lt: (v, t) => v < t };

export async function evaluate(input, io) {
  const deviceId = String(input.deviceId || '');
  const metric = String(input.metric || '');
  const value = Number(input.value);
  const at = String(input.at || new Date().toISOString());

  if (!deviceId || !metric || !Number.isFinite(value)) return { result: false };

  const device = await io['fetch']('Device', deviceId);
  if (!device) return { result: false };

  const own = await io.find('Rule', { where: { deviceId, metric, active: true }, limit: 50 });
  const shared = await io.find('Rule', { where: { deviceId: '*', metric, active: true }, limit: 50 });
  const rules = [...(own.items || []), ...(shared.items || [])];
  if (rules.length === 0) return { result: true };

  const now = Date.now();
  let opened = 0;

  for (const rule of rules) {
    const compare = EVAL_OPS[rule.op];
    if (!compare || !compare(value, Number(rule.threshold))) continue;

    if (rule.lastAlertAt) {
      const elapsed = (now - Date.parse(rule.lastAlertAt)) / 1000;
      if (elapsed < Number(rule.cooldownSec || 0)) continue;
    }

    const alert = {
      id: await io.new(),
      ruleId: rule.id,
      deviceId,
      metric,
      value,
      severity: rule.severity || 'warning',
      status: 'open',
      openedAt: at,
      notifiedAt: null,
      ackedAt: null,
      resolvedAt: null,
      note: null,
    };
    await io.insert('Alert', alert);
    await io.update('Rule', rule.id, { lastAlertAt: new Date().toISOString() });

    const reply = await io.remote('Pager', 'notify', {
      alertId: alert.id,
      deviceId,
      metric,
      value: String(value),
      severity: alert.severity,
    });
    const delivered = reply && reply.status >= 200 && reply.status < 300 && reply.body && reply.body.delivered === true;
    if (!delivered) {
      // The alert row stays open; a retry opens no second one because the
      // cooldown is already stamped.
      throw new Error('pager rejected alert ' + alert.id + ': ' + JSON.stringify(reply && reply.status));
    }
    await io.update('Alert', alert.id, { notifiedAt: new Date().toISOString() });
    opened += 1;
  }

  return { result: opened > 0 };
}
