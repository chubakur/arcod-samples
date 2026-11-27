export async function caseEvidence(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const caseId = String(body.caseId || '');
  const row = await io.fetch('Case', caseId);
  if (!row || !row.evidenceKey) return { error: 'NotFound' };
  const bodyText = await io.blobGet(row.evidenceKey);
  const content = bodyText == null ? '' : String(bodyText);
  return { result: { key: row.evidenceKey, content, bytes: content.length } };
}
