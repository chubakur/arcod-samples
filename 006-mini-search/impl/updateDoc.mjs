// Replace a document in place with a new generation.
//
// Postings at version+1 are written before Doc.version moves. Until the update
// lands, search still sees version N and ignores every new posting. A rival
// writer that picked the same version loses on the composite claim; the winner
// is the one whose update commits.

const UPD_STOP = new Set([
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

function updWords(text) {
  return String(text == null ? '' : text)
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((word) => word.length >= 2 && word.length <= 40);
}

function updTokens(text) {
  return updWords(text).filter((word) => !UPD_STOP.has(word));
}

function updCount(tokens) {
  const counts = new Map();
  for (const token of tokens) counts.set(token, (counts.get(token) || 0) + 1);
  return counts;
}

function updCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

function updIso(ms) {
  return new Date(ms).toISOString();
}

async function updTerm(io, term, now) {
  try {
    await io.insert('Term', { id: term, term, at: now });
  } catch (err) {
    if (updCode(err) !== 'Conflict') throw err;
  }
}

async function updCorpus(io, docs, length, now) {
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
      if (updCode(err) !== 'Conflict') throw err;
    }
    return;
  }
  await io.update('Corpus', 'main', {
    documents: Math.max(0, Number(corpus.documents) + docs),
    totalLength: Math.max(0, Number(corpus.totalLength) + length),
    updatedAt: now,
  });
}

async function updDrop(io, docId, version) {
  let cursor = null;
  do {
    const query = { where: { docId }, limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('Posting', query);
    for (const posting of page.items || []) {
      if (Number(posting.version) < version) {
        await io.remove('Posting', posting.id);
      }
    }
    cursor = page.next || null;
  } while (cursor);
}

export async function updateDoc(input, io) {
  const id = String(input.id == null ? '' : input.id);
  const title = String(input.title == null ? '' : input.title).trim();
  const body = String(input.body == null ? '' : input.body);
  const tags = String(input.tags == null ? '' : input.tags).trim();

  if (!id) return { error: 'NotFound' };
  if (title.length < 1 || title.length > 200) return { error: 'Invalid' };
  if (body.length < 1 || body.length > 20000) return { error: 'Invalid' };
  if (tags.length > 200) return { error: 'Invalid' };

  const previous = await io.fetch('Doc', id);
  if (!previous) return { error: 'NotFound' };

  const now = Date.now();
  const at = updIso(now);
  const version = Number(previous.version || 0) + 1;
  const titleCounts = updCount(updTokens(title));
  const bodyCounts = updCount(updTokens(body));
  const terms = new Set([...titleCounts.keys(), ...bodyCounts.keys()]);
  const written = [];

  for (const term of terms) await updTerm(io, term, at);

  for (const term of terms) {
    const postingId = term + '#' + id + '#' + version;
    const titleTf = titleCounts.get(term) || 0;
    const tf = titleTf + (bodyCounts.get(term) || 0);
    try {
      await io.insert('Posting', {
        id: postingId,
        term,
        docId: id,
        version,
        tf,
        titleTf,
      });
      written.push(postingId);
    } catch (err) {
      if (updCode(err) !== 'Conflict') throw err;
      // This generation lost. Take our partial attempt back out so a retry of
      // the same version starts from a clean slate.
      for (const own of written) await io.remove('Posting', own);
      return { error: 'Conflict' };
    }
  }

  const length = [...titleCounts.values()].reduce((a, b) => a + b, 0)
    + [...bodyCounts.values()].reduce((a, b) => a + b, 0);

  const doc = {
    id,
    title,
    body,
    tags,
    length,
    version,
    createdAt: previous.createdAt,
    updatedAt: at,
  };

  // The update is the commit: search starts seeing version+1 here.
  await io.update('Doc', id, {
    title,
    body,
    tags,
    length,
    version,
    updatedAt: at,
  });

  await updCorpus(io, 0, length - Number(previous.length || 0), at);
  await updDrop(io, id, version);

  return { result: { doc, postings: terms.size, terms: terms.size } };
}
