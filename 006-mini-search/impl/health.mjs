export async function health(input, io) {
  const corpus = await io.fetch('Corpus', 'main');
  return {
    result: {
      ok: true,
      documents: corpus ? Number(corpus.documents) : 0,
    },
  };
}
