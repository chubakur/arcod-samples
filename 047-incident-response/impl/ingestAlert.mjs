// The dedup window lives in SQL: an open incident with the same fingerprint
// younger than five minutes absorbs the alert. The kv store cannot be mixed
// with sql in one service (A094), so the window is a row lookup, not a TTL.
const WINDOW_MS = 5 * 60 * 1000;

export async function ingestAlert(input, io) {
  const serviceId = String(input.serviceId || '');
  const fingerprint = String(input.fingerprint || '').trim() || String(input.title || '').trim();
  const title = String(input.title || '').trim();
  const severity = String(input.severity || 'SEV2').toUpperCase();
  const observedAt = input.observedAt ? Date.parse(String(input.observedAt)) : Date.now();

  const service = await io.fetch('Service', serviceId);
  if (!service) return { error: 'NotFound', serviceId };
  if (!title || title.length > 200 || !fingerprint) return { error: 'Invalid', title };
  if (!['SEV1', 'SEV2', 'SEV3', 'SEV4'].includes(severity)) return { error: 'Invalid', title };
  if (!Number.isFinite(observedAt)) return { error: 'Invalid', title };

  const page = await io.find('Incident', {
    where: { serviceId, fingerprint },
    order: 'openedAt desc',
    limit: 5
  });
  const open = (page.items || []).find(
    (row) => row.status !== 'resolved' && observedAt - Date.parse(row.openedAt) < WINDOW_MS
  );

  if (open) {
    const dedupCount = Number(open.dedupCount || 0) + 1;
    await io.update('Incident', open.id, { dedupCount });
    await io.insert('IncidentEvent', {
      id: await io.new(),
      incidentId: open.id,
      kind: 'deduped',
      actor: 'monitor',
      detail: severity + ' ' + title,
      at: new Date(observedAt).toISOString()
    });
    return {
      result: {
        incidentId: open.id,
        deduped: true,
        status: open.status,
        assignee: String(open.assignee || ''),
        dedupCount
      }
    };
  }

  const row = {
    id: await io.new(),
    serviceId,
    title,
    fingerprint,
    severity,
    status: 'open',
    assignee: '',
    dedupCount: 1,
    openedAt: new Date(observedAt).toISOString(),
    ackedAt: null,
    resolvedAt: null,
    summary: '',
    postmortemKey: '',
    escalated: false
  };
  await io.insert('Incident', row);
  await io.insert('IncidentEvent', {
    id: await io.new(),
    incidentId: row.id,
    kind: 'opened',
    actor: 'monitor',
    detail: severity + ' ' + title,
    at: row.openedAt
  });
  await io.queuePublish('notify', row.id);
  return {
    result: { incidentId: row.id, deduped: false, status: 'open', assignee: '', dedupCount: 1 }
  };
}
