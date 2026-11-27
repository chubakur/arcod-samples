// The request only stores the text and enqueues it. Scoring, the S3 evidence
// snapshot and routing all happen in the screen consumer.
const SUBMIT_KINDS = ['post', 'comment', 'profile'];

export async function submit(input, io) {
  const actor = await io.actor();
  const kind = String(input.kind || '').trim();
  const text = String(input.text || '').trim();

  if (SUBMIT_KINDS.indexOf(kind) < 0) return { error: 'Invalid' };
  if (!text || text.length > 5000) return { error: 'Invalid' };

  const now = new Date().toISOString();
  const row = {
    id: await io.new(),
    author: actor.id,
    authorName: actor.name,
    kind,
    text,
    status: 'screening',
    risk: 0,
    flags: '',
    policyVersion: 0,
    reason: '',
    decidedBy: '',
    createdAt: now,
    updatedAt: now,
    decidedAt: null,
    dueAt: null,
    escalated: false,
    evidenceKey: '',
  };
  await io.insert('Item', row);
  await io.insert('Audit', {
    id: await io.new(),
    actor: actor.id,
    action: 'item.submitted',
    itemId: row.id,
    detail: kind + ' ' + text.length + ' chars',
    at: now,
  });
  await io.queuePublish('screen', row.id);
  return { result: row };
}
