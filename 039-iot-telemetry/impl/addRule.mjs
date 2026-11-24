const RULE_OPS = { gt: (v, t) => v > t, lt: (v, t) => v < t };
const SEVERITIES = { warning: true, critical: true };

export async function addRule(input, io) {
  const rule = input.rule || {};
  const deviceId = String(rule.deviceId || '*').trim() || '*';
  const metric = String(rule.metric || '').trim();
  const op = String(rule.op || 'gt').trim();
  const threshold = Number(rule.threshold);
  const cooldownSec = Number(rule.cooldownSec == null ? 300 : rule.cooldownSec);
  const severity = String(rule.severity || 'warning').trim();

  if (!metric || metric.length > 60) return { error: 'Invalid' };
  if (!RULE_OPS[op]) return { error: 'Invalid' };
  if (!Number.isFinite(threshold)) return { error: 'Invalid' };
  if (!Number.isFinite(cooldownSec) || cooldownSec < 0 || cooldownSec > 86400) return { error: 'Invalid' };
  if (!SEVERITIES[severity]) return { error: 'Invalid' };

  const row = {
    id: await io.new(),
    deviceId,
    metric,
    op,
    threshold,
    cooldownSec: Math.round(cooldownSec),
    severity,
    active: true,
    lastAlertAt: null,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Rule', row);
  return { result: row };
}
