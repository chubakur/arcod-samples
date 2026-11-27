export async function attempt(input, io) {
  const body = input && typeof input === 'object' ? input : {};
  const id = String(body.attemptId || '');
  const row = await io.fetch('Attempt', id);
  if (!row) return { error: 'NotFound' };

  const decisions = await io.find('Decision', { where: { attemptId: id }, limit: 1 });
  const cases = await io.find('Case', { where: { attemptId: id }, order: 'openedAt desc', limit: 10 });
  return {
    result: {
      attempt: row,
      decision: decisions.items || [],
      cases: cases.items || [],
    },
  };
}
