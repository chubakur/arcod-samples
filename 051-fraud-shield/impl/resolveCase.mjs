// The reviewer's decision on an open case. A second resolve is a conflict so
// the first reviewer's notes are not overwritten. The read-then-update is not
// atomic (no CAS on update, #58): in production two reviewers can race here,
// which is why the case row, not the HTTP retry, is the record of truth.
export async function resolveCase(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const caseId = String(body.caseId || '');
  const row = await io.fetch('Case', caseId);
  if (!row) return { error: 'NotFound' };
  if (row.status === 'resolved') return { error: 'Conflict' };

  const patch = {
    status: 'resolved',
    assignee: String(body.assignee || '').trim(),
    notes: String(body.notes || '').trim(),
    resolvedAt: new Date().toISOString(),
  };
  await io.update('Case', caseId, patch);
  return { result: Object.assign({}, row, patch) };
}
