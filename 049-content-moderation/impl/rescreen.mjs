// Consumer 3: a new policy re-scores content that an older policy approved
// automatically. Human decisions are never overwritten. Pulling a row back to
// pending resets the SLA clock and makes it visible in the review queue.
export async function rescreen(input, io) {
  const policyId = typeof input === 'string' ? input : String((input && input.policyId) || '');
  if (!policyId) return { result: false };
  const policy = await io.fetch('Policy', policyId);
  if (!policy) return { result: false };

  const page = await io.find('Item', { where: { status: 'approved' }, limit: 500 });
  let changed = 0;
  for (const row of page.items || []) {
    if (String(row.decidedBy || '').indexOf('policy:') !== 0) continue;
    const score = rsScore(row.text, policy);
    if (score.risk < Number(policy.threshold)) continue;

    const now = new Date().toISOString();
    const key = 'evidence/' + row.id + '.json';
    const snapshot = {
      itemId: row.id,
      policyVersion: Number(policy.version),
      threshold: Number(policy.threshold),
      risk: score.risk,
      flags: score.flags,
      matched: score.matched,
      links: score.links,
      previous: row.decidedBy,
      at: now,
    };
    await io.blobPut(key, JSON.stringify(snapshot), 'application/json');
    await io.update('Item', row.id, {
      status: 'pending',
      risk: score.risk,
      flags: score.flags,
      policyVersion: Number(policy.version),
      reason: 'rescreen: risk ' + score.risk + ' >= ' + policy.threshold,
      decidedBy: '',
      decidedAt: null,
      dueAt: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
      escalated: false,
      evidenceKey: key,
      updatedAt: now,
    });
    await io.insert('Audit', {
      id: await io.new(),
      actor: 'system',
      action: 'item.rescreened',
      itemId: row.id,
      detail: 'policy v' + policy.version + ': risk ' + score.risk,
      at: now,
    });
    await io.queuePublish('notify', row.id);
    changed += 1;
  }
  return { result: { changed } };
}

function rsScore(text, policy) {
  const haystack = String(text || '').toLowerCase();
  const terms = String(policy.terms || '')
    .split(',')
    .map((term) => term.trim().toLowerCase())
    .filter((term) => term.length > 0);
  const matched = terms.filter((term) => haystack.indexOf(term) >= 0);
  const links = (haystack.match(/https?:\/\//g) || []).length;
  const linkWeight = Number(policy.linkWeight) || 0;
  const risk = Math.min(100, matched.length * 30 + links * linkWeight);
  const flags = matched.concat(links ? ['links:' + links] : []).join(',');
  return { risk, matched, links, flags };
}
