// Rule configuration is validated here rather than in the consumer: a bad
// rule must be rejected when it is written, not silently skipped on every
// payment. A blocklist matches the card fingerprint exactly; the other kinds
// use threshold (and windowSeconds for velocity).
const FRK_KINDS = ['blocklist', 'amount_limit', 'velocity', 'score'];
const FRK_ACTIONS = ['review', 'decline'];

export async function createRule(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const name = String(body.name || '').trim();
  const kind = String(body.kind || '').trim();
  const action = String(body.action || 'review').trim();
  const value = String(body.value || '').trim();
  const threshold = Number(body.threshold == null ? 0 : body.threshold);
  const windowSeconds = Number(body.windowSeconds == null ? 0 : body.windowSeconds);

  if (!name || FRK_KINDS.indexOf(kind) < 0) return { error: 'Invalid' };
  if (FRK_ACTIONS.indexOf(action) < 0) return { error: 'Invalid' };
  if (!Number.isInteger(threshold) || threshold < 0) return { error: 'Invalid' };
  if (!Number.isInteger(windowSeconds) || windowSeconds < 0) return { error: 'Invalid' };
  if (kind === 'blocklist' && !value) return { error: 'Invalid' };
  if ((kind === 'amount_limit' || kind === 'score') && threshold <= 0) return { error: 'Invalid' };
  if (kind === 'velocity' && (threshold <= 0 || windowSeconds <= 0)) return { error: 'Invalid' };

  const rule = {
    id: await io.new(),
    name,
    kind,
    value: kind === 'blocklist' ? value : '',
    threshold,
    windowSeconds: kind === 'velocity' ? windowSeconds : 0,
    action,
    enabled: true,
    createdAt: new Date().toISOString(),
  };
  await io.insert('Rule', rule);
  return { result: rule };
}
