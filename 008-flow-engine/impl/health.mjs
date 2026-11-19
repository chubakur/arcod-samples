async function countEntities(io, entity) {
  let total = 0;
  let cursor = null;
  do {
    const query = { limit: 200 };
    if (cursor) query.cursor = cursor;
    const page = await io.find(entity, query);
    total += (page.items || []).length;
    if (total >= 2000) break;
    cursor = page.next || null;
  } while (cursor);
  return total;
}

export async function health(input, io) {
  const workflows = await countEntities(io, 'WorkflowRec');
  const runs = await countEntities(io, 'RunRec');
  return { result: { ok: true, workflows, runs } };
}
