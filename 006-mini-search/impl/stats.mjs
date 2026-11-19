// Honest index counters. Corpus is the fast path; the scan is the proof. When
// they disagree (a racing writer, a crash between writes) the response shows
// both instead of hiding the drift.

async function stScan(io, entity, cap) {
  const items = [];
  let cursor = null;
  do {
    const query = { limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find(entity, query);
    for (const item of page.items || []) items.push(item);
    if (items.length >= cap) break;
    cursor = page.next || null;
  } while (cursor);
  return items;
}

export async function stats(input, io) {
  const corpus = await io.fetch('Corpus', 'main');
  const docs = await stScan(io, 'Doc', 10000);
  const postings = await stScan(io, 'Posting', 10000);
  const terms = await stScan(io, 'Term', 10000);

  const totalLength = docs.reduce((sum, doc) => sum + Number(doc.length || 0), 0);
  const avgLength = docs.length > 0 ? totalLength / docs.length : 0;

  return {
    result: {
      documents: corpus ? Number(corpus.documents) : docs.length,
      scannedDocs: docs.length,
      postings: postings.length,
      terms: terms.length,
      avgLength: Math.round(avgLength * 100) / 100,
    },
  };
}
