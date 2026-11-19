// Prefix suggestions from the vocabulary. Terms are kept after their last
// document disappears: a suggestion is a hint, not a promise that the term has
// a live posting.

function sugNorm(raw) {
  return String(raw == null ? '' : raw)
    .toLowerCase()
    .replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '');
}

export async function suggest(input, io) {
  const prefix = sugNorm(input.prefix);
  const limit = Number(input.limit == null ? 8 : input.limit);

  if (prefix.length < 1 || prefix.length > 40) return { error: 'Invalid' };
  if (!Number.isInteger(limit) || limit < 1 || limit > 50) return { error: 'Invalid' };

  const page = await io.find('Term', {
    where: { term: { gte: prefix, lt: prefix + '\uffff' } },
    order: 'term asc',
    limit,
  });

  const terms = [];
  for (const item of page.items || []) {
    const term = String(item.term || '');
    if (term.startsWith(prefix) && !terms.includes(term)) terms.push(term);
    if (terms.length >= limit) break;
  }
  return { result: terms };
}
