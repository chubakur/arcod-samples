// Ranked search over the posting lists.
//
// A query is parsed into optional terms, required (+), excluded (-), phrases
// ("...") and tag filters. A document is a candidate if it has a live posting
// for any positive term; required terms and filters then remove candidates.
// Scoring is BM25 with a title boost.

const SRCH_STOP = new Set([
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

function srchNorm(raw) {
  return String(raw == null ? '' : raw)
    .toLowerCase()
    .replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '');
}

function srchFlat(text) {
  return String(text == null ? '' : text)
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function srchParse(raw) {
  const text = String(raw == null ? '' : raw).trim();
  const parts = text.match(/"([^"]*)"|(\S+)/g) || [];
  const terms = [];
  const required = [];
  const excluded = [];
  const tags = [];
  const phrases = [];

  for (const part of parts) {
    if (part.length > 1 && part[0] === '"' && part[part.length - 1] === '"') {
      const phrase = srchFlat(part.slice(1, -1));
      if (phrase) phrases.push(phrase);
      continue;
    }
    if (part.length > 1 && part[0] === '-') {
      const term = srchNorm(part.slice(1));
      if (term && !SRCH_STOP.has(term)) excluded.push(term);
      continue;
    }
    if (part.length > 1 && part[0] === '+') {
      const term = srchNorm(part.slice(1));
      if (term && !SRCH_STOP.has(term)) required.push(term);
      continue;
    }
    if (part.toLowerCase().startsWith('tag:')) {
      const tag = srchNorm(part.slice(4));
      if (tag) tags.push(tag);
      continue;
    }
    const term = srchNorm(part);
    if (term && !SRCH_STOP.has(term)) terms.push(term);
  }

  return {
    raw: text,
    terms: [...new Set(terms)],
    required: [...new Set(required)],
    excluded: [...new Set(excluded)],
    tags: [...new Set(tags)],
    phrases: [...new Set(phrases)],
  };
}

function srchCode(err) {
  return (err && (err.error || err.code || err.name)) || '';
}

async function srchPostings(io, terms) {
  if (terms.length === 0) return [];
  const wanted = terms.slice(0, 32);
  const items = [];
  let cursor = null;
  do {
    const query = { where: { term: { in: wanted } }, limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('Posting', query);
    for (const posting of page.items || []) items.push(posting);
    if (items.length >= 5000) break;
    cursor = page.next || null;
  } while (cursor);
  return items;
}

function srchEscape(text) {
  return String(text)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function srchSnippet(text, terms) {
  const source = String(text == null ? '' : text).replace(/\s+/g, ' ').trim();
  if (!source) return '';
  const lower = source.toLowerCase();
  let first = -1;
  for (const term of terms) {
    const at = lower.indexOf(term);
    if (at >= 0 && (first < 0 || at < first)) first = at;
  }
  if (first < 0) first = 0;

  let start = Math.max(0, first - 80);
  let end = Math.min(source.length, start + 200);
  if (start > 0) {
    const space = source.indexOf(' ', start);
    if (space > 0 && space < first) start = space + 1;
  }
  if (end < source.length) {
    const space = source.lastIndexOf(' ', end);
    if (space > start) end = space;
  }

  let out = srchEscape(source.slice(start, end));
  const ordered = [...terms].sort((a, b) => b.length - a.length);
  for (const term of ordered) {
    const safe = term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    out = out.replace(new RegExp('\\b' + safe + '\\b', 'gi'), '<mark>$&</mark>');
  }
  return (start > 0 ? '…' : '') + out + (end < source.length ? '…' : '');
}

export async function search(input, io) {
  const started = Date.now();
  const parsed = srchParse(input.q);
  const limit = Number(input.limit == null ? 10 : input.limit);
  const offset = Number(input.offset == null ? 0 : input.offset);

  if (!Number.isInteger(limit) || limit < 1 || limit > 50) return { error: 'Invalid' };
  if (!Number.isInteger(offset) || offset < 0 || offset > 1000) return { error: 'Invalid' };
  if (parsed.terms.length + parsed.required.length + parsed.phrases.length === 0) {
    return { error: 'Invalid' };
  }

  // A quoted phrase has no operators, but it still has to produce candidate
  // postings; the phrase itself is verified against the document text later.
  const phraseTerms = [];
  for (const phrase of parsed.phrases) {
    for (const word of phrase.split(' ')) {
      if (word.length >= 2 && !SRCH_STOP.has(word)) phraseTerms.push(word);
    }
  }

  const positive = [...new Set([...parsed.terms, ...parsed.required, ...phraseTerms])];
  const allTerms = [...new Set([...positive, ...parsed.excluded])];
  const postings = await srchPostings(io, allTerms);

  const grouped = new Map();
  for (const posting of postings) {
    const key = String(posting.docId);
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(posting);
  }

  // One page of ids instead of one fetch per candidate. io.fetch is a single
  // round trip by design; a search would otherwise turn a 200-document result
  // into 200 of them.
  const ids = [...grouped.keys()];
  const docsById = new Map();
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    let docCursor = null;
    do {
      const query = { where: { id: { in: chunk } }, limit: 200 };
      if (docCursor) query.cursor = docCursor;
      const page = await io.find('Doc', query);
      for (const doc of page.items || []) docsById.set(String(doc.id), doc);
      docCursor = page.next || null;
    } while (docCursor);
  }

  const corpus = await io.fetch('Corpus', 'main');
  const live = [];
  for (const [docId, rows] of grouped) {
    const doc = docsById.get(docId);
    if (!doc) continue;
    const version = Number(doc.version);
    const current = rows.filter((row) => Number(row.version) === version);
    if (current.length === 0) continue;
    live.push({ doc, rows: current, terms: new Set(current.map((row) => row.term)) });
  }

  // df is counted before required/tag filters: a document that contains the
  // term at all is already in this candidate set.
  const df = new Map();
  for (const entry of live) {
    for (const term of entry.terms) df.set(term, (df.get(term) || 0) + 1);
  }

  const docs = Number(corpus && corpus.documents) || live.length;
  const totalLength = Number(corpus && corpus.totalLength) || 0;
  const avgdl = docs > 0 && totalLength > 0
    ? totalLength / docs
    : (live.length > 0
      ? live.reduce((sum, entry) => sum + Number(entry.doc.length || 0), 0) / live.length
      : 1);
  const k1 = 1.2;
  const b = 0.75;

  const matchedDocs = [];
  for (const entry of live) {
    const doc = entry.doc;
    if (parsed.excluded.some((term) => entry.terms.has(term))) continue;
    if (!parsed.required.every((term) => entry.terms.has(term))) continue;

    const docTags = String(doc.tags || '')
      .toLowerCase()
      .split(/[,;\s]+/)
      .filter(Boolean);
    if (!parsed.tags.every((tag) => docTags.includes(tag))) continue;

    const flat = srchFlat(String(doc.title || '') + ' ' + String(doc.body || ''));
    if (!parsed.phrases.every((phrase) => flat.includes(phrase))) continue;

    let score = 0;
    const matched = [];
    for (const row of entry.rows) {
      if (!positive.includes(row.term)) continue;
      const termDf = df.get(row.term) || 1;
      const idf = Math.log(1 + (docs - termDf + 0.5) / (termDf + 0.5));
      const tf = Math.max(1, Number(row.tf) || 1);
      const dl = Math.max(1, Number(doc.length) || 1);
      const norm = 1 - b + b * (dl / Math.max(1, avgdl));
      const boost = Number(row.titleTf) > 0 ? 1.6 : 1;
      score += idf * ((tf * (k1 + 1)) / (tf + k1 * norm)) * boost;
      matched.push(row.term);
    }
    if (parsed.phrases.length > 0) score += parsed.phrases.length * 1.5;

    matchedDocs.push({
      docId: doc.id,
      title: doc.title,
      tags: doc.tags,
      score: Math.round(score * 10000) / 10000,
      snippet: srchSnippet(doc.body, matched.length > 0 ? matched : positive),
      matched: [...new Set(matched)],
    });
  }

  matchedDocs.sort((a, b2) => b2.score - a.score || String(a.title).localeCompare(String(b2.title)));
  const total = matchedDocs.length;
  const hits = matchedDocs.slice(offset, offset + limit);

  return {
    result: {
      query: parsed.raw,
      total,
      offset,
      limit,
      tookMs: Date.now() - started,
      hits,
    },
  };
}
