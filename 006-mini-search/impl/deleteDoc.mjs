// Delete the document first, then clean postings. Search joins postings to a
// live Doc, so a crash in the middle leaves garbage that cannot answer.

function delIso(ms) {
  return new Date(ms).toISOString();
}

async function delCorpus(io, docs, length, now) {
  const corpus = await io.fetch('Corpus', 'main');
  if (!corpus) return;
  await io.update('Corpus', 'main', {
    documents: Math.max(0, Number(corpus.documents) + docs),
    totalLength: Math.max(0, Number(corpus.totalLength) + length),
    updatedAt: now,
  });
}

async function delPostings(io, docId) {
  let removed = 0;
  let cursor = null;
  do {
    const query = { where: { docId }, limit: 500 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('Posting', query);
    for (const posting of page.items || []) {
      await io.remove('Posting', posting.id);
      removed += 1;
    }
    cursor = page.next || null;
  } while (cursor);
  return removed;
}

export async function deleteDoc(input, io) {
  const id = String(input.id == null ? '' : input.id);
  const doc = await io.fetch('Doc', id);
  if (!doc) return { error: 'NotFound' };

  await io.remove('Doc', id);
  const removed = await delPostings(io, id);
  await delCorpus(io, -1, -Number(doc.length || 0), delIso(Date.now()));

  return { result: { deleted: true, postings: removed } };
}
