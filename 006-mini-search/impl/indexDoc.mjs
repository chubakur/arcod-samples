// Index one new document.
//
// The document is written last: search joins postings to a Doc, so postings
// without a document are invisible. A crash between the two leaves garbage,
// never a half-visible document.

const IDX_STOP = new Set([
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'with', 'by',
  'is', 'are', 'was', 'were', 'be', 'been', 'at', 'as', 'it', 'its', 'this',
  'that', 'from', 'into', 'over', 'after', 'before', 'can', 'cannot', 'not',
  'no', 'so', 'if', 'then', 'than', 'but', 'each', 'every', 'all', 'any',
  'и', 'в', 'во', 'не', 'что', 'он', 'на', 'я', 'с', 'со', 'как', 'а', 'то',
  'все', 'она', 'так', 'его', 'но', 'да', 'ты', 'к', 'у', 'же', 'вы', 'за',
  'бы', 'по', 'только', 'ее', 'мне', 'было', 'вот', 'от', 'меня', 'еще',
  'нет', 'о', 'из', 'ему', 'теперь', 'когда', 'даже', 'ну', 'вдруг', 'ли',
  'если', 'уже', 'или', 'ни', 'быть', 'был', 'него', 'до', 'вас', 'нибудь',
]);

function idxWords(text) {
  return String(text == null ? '' : text)
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((word) => word.length >= 2 && word.length <= 40);
}

function idxTokens(text) {
  return idxWords(text).filter((word) => !IDX_STOP.has(word));
}

function idxCount(tokens) {
  const counts = new Map();
  for (const token of tokens) counts.set(token, (counts.get(token) || 0) + 1);
  return counts;
}

function idxCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

function idxIso(ms) {
  return new Date(ms).toISOString();
}

async function idxTerm(io, term, now) {
  try {
    await io.insert('Term', { id: term, term, at: now });
  } catch (err) {
    if (idxCode(err) !== 'Conflict') throw err;
  }
}

async function idxCorpus(io, docs, length, now) {
  const corpus = await io.fetch('Corpus', 'main');
  if (!corpus) {
    try {
      await io.insert('Corpus', {
        id: 'main',
        documents: Math.max(0, docs),
        totalLength: Math.max(0, length),
        updatedAt: now,
      });
    } catch (err) {
      if (idxCode(err) !== 'Conflict') throw err;
    }
    return;
  }
  await io.update('Corpus', 'main', {
    documents: Math.max(0, Number(corpus.documents) + docs),
    totalLength: Math.max(0, Number(corpus.totalLength) + length),
    updatedAt: now,
  });
}

export async function indexDoc(input, io) {
  const title = String(input.title == null ? '' : input.title).trim();
  const body = String(input.body == null ? '' : input.body);
  const tags = String(input.tags == null ? '' : input.tags).trim();

  if (title.length < 1 || title.length > 200) return { error: 'Invalid' };
  if (body.length < 1 || body.length > 20000) return { error: 'Invalid' };
  if (tags.length > 200) return { error: 'Invalid' };

  const now = Date.now();
  const at = idxIso(now);
  const id = await io.new();
  const version = 1;

  const titleCounts = idxCount(idxTokens(title));
  const bodyCounts = idxCount(idxTokens(body));
  const terms = new Set([...titleCounts.keys(), ...bodyCounts.keys()]);

  for (const term of terms) await idxTerm(io, term, at);

  for (const term of terms) {
    const titleTf = titleCounts.get(term) || 0;
    const tf = titleTf + (bodyCounts.get(term) || 0);
    try {
      await io.insert('Posting', {
        id: term + '#' + id + '#' + version,
        term,
        docId: id,
        version,
        tf,
        titleTf,
      });
    } catch (err) {
      // A duplicate posting at the same generation means another writer is
      // indexing this document. The document has not been committed yet, so
      // nothing from this attempt is visible.
      if (idxCode(err) === 'Conflict') return { error: 'Conflict' };
      throw err;
    }
  }

  const doc = {
    id,
    title,
    body,
    tags,
    length: [...titleCounts.values()].reduce((a, b) => a + b, 0)
      + [...bodyCounts.values()].reduce((a, b) => a + b, 0),
    version,
    createdAt: at,
    updatedAt: at,
  };
  await io.insert('Doc', doc);
  await idxCorpus(io, 1, doc.length, at);

  return { result: { doc, postings: terms.size, terms: terms.size } };
}
