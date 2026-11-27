// Consumer 1: score against the active policy, write the evidence snapshot to
// S3, then route. Clean content is approved automatically and names the policy
// version as its decider; risky content becomes a human task with a 24h clock.
export async function screen(input, io) {
  const itemId = typeof input === 'string' ? input : String((input && input.itemId) || '');
  if (!itemId) return { result: false };
  const row = await io.fetch('Item', itemId);
  if (!row) return { result: false };
  if (row.status !== 'screening') return { result: true };

  const policyPage = await io.find('Policy', { where: { active: true }, order: 'version desc', limit: 1 });
  const policy = (policyPage.items || [])[0] || null;
  const score = scScore(row.text, policy);
  const now = new Date().toISOString();

  const key = 'evidence/' + itemId + '.json';
  const snapshot = {
    itemId,
    policyVersion: policy ? Number(policy.version) : 0,
    threshold: policy ? Number(policy.threshold) : null,
    risk: score.risk,
    flags: score.flags,
    matched: score.matched,
    links: score.links,
    at: now,
  };
  await io.blobPut(key, JSON.stringify(snapshot), 'application/json');

  let status = 'pending';
  let reason = 'no active policy';
  let decidedBy = '';
  let decidedAt = null;
  let dueAt = new Date(Date.now() + 24 * 3600 * 1000).toISOString();

  if (policy) {
    if (score.risk >= Number(policy.threshold)) {
      reason = 'risk ' + score.risk + ' >= ' + policy.threshold;
    } else {
      status = 'approved';
      reason = 'auto: risk ' + score.risk + ' < ' + policy.threshold;
      decidedBy = 'policy:v' + policy.version;
      decidedAt = now;
      dueAt = null;
    }
  }

  await io.update('Item', itemId, {
    status,
    risk: score.risk,
    flags: score.flags,
    policyVersion: policy ? Number(policy.version) : 0,
    reason,
    decidedBy,
    decidedAt,
    dueAt,
    evidenceKey: key,
    updatedAt: now,
  });
  await io.insert('Audit', {
    id: await io.new(),
    actor: 'system',
    action: 'item.screened',
    itemId,
    detail: status + ' ' + reason,
    at: now,
  });
  await io.queuePublish('notify', itemId);
  return { result: true };
}

function scScore(text, policy) {
  const haystack = String(text || '').toLowerCase();
  const terms = policy
    ? String(policy.terms || '')
        .split(',')
        .map((term) => term.trim().toLowerCase())
        .filter((term) => term.length > 0)
    : [];
  const matched = terms.filter((term) => haystack.indexOf(term) >= 0);
  const links = (haystack.match(/https?:\/\//g) || []).length;
  const linkWeight = policy ? Number(policy.linkWeight) || 0 : 0;
  const risk = Math.min(100, matched.length * 30 + links * linkWeight);
  const flags = matched.concat(links ? ['links:' + links] : []).join(',');
  return { risk, matched, links, flags };
}
