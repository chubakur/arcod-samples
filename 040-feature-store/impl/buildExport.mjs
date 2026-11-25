// Point-in-time join: for every entity and feature take the last value at or
// before the window end, then attach attributes from the profile service. The
// CSV is immutable; the row in Export only points at it.
function csvCell(value) {
  const text = String(value ?? '');
  return /[",\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
}

export async function buildExport(input, io) {
  const id = String(input.exportId || '').trim();
  if (!id) return { result: false };
  const row = await io.fetch('Export', id);
  if (!row) return { result: false };
  if (row.status === 'done') return { result: true };

  try {
    const names = Array.isArray(row.features) ? row.features.map(String) : [];
    const fromMs = Date.parse(row.fromAt);
    const toMs = Date.parse(row.toAt);

    const latest = new Map();
    for (const name of names) {
      const found = await io.find('Event', { where: { feature: name }, limit: 2000 });
      for (const event of found.items || []) {
        const at = Date.parse(event.at);
        if (Number.isNaN(at) || at < fromMs || at > toMs) continue;
        const key = name + '|' + event.entityId;
        const prev = latest.get(key);
        if (!prev || Date.parse(prev.at) <= at) latest.set(key, event);
      }
    }

    const entities = [...new Set([...latest.values()].map((e) => String(e.entityId)))].sort();
    const profiles = new Map();
    for (const entityId of entities) {
      const reply = await io.remote('Profiles', 'lookup', { entityId });
      const body = reply && reply.body !== undefined ? reply.body : reply;
      if (!body || typeof body !== 'object') {
        throw new Error('profile lookup failed for ' + entityId + ': ' + JSON.stringify(reply));
      }
      profiles.set(entityId, body);
    }

    const lines = ['entityId,segment,country,plan,feature,value,at,version'];
    let rows = 0;
    for (const name of names) {
      for (const entityId of entities) {
        const event = latest.get(name + '|' + entityId);
        if (!event) continue;
        const profile = profiles.get(entityId) || {};
        lines.push(
          [
            entityId,
            csvCell(profile.segment),
            csvCell(profile.country),
            csvCell(profile.plan),
            name,
            csvCell(event.value),
            event.at,
            Number(event.version || 1),
          ].join(','),
        );
        rows += 1;
      }
    }

    const key = 'exports/' + id + '.csv';
    await io.blobPut(key, lines.join('\n') + '\n');
    await io.update('Export', id, {
      status: 'done',
      rows,
      key,
      error: null,
      finishedAt: new Date().toISOString(),
    });
    return { result: true };
  } catch (err) {
    await io.update('Export', id, {
      status: 'failed',
      error: String((err && err.message) || err).slice(0, 400),
      finishedAt: new Date().toISOString(),
    });
    throw err;
  }
}
