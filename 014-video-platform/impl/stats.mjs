// Store has no aggregate in this build path (see ISSUES #34), and io.count is
// one query per status; the library figures are a page read and a fold. It is
// honest for 1000 rows, not for a million: that is the line where this sample
// would need an OLAP projection.
export async function stats(input, io) {
  const all = await io.find('Video', { limit: 1000 });
  const rows = all.items || [];
  const count = (status) => rows.filter((row) => row.status === status).length;
  const sourceBytes = rows.reduce((sum, row) => sum + Number(row.sourceBytes || 0), 0);
  return {
    result: {
      total: rows.length,
      ready: count('ready'),
      failed: count('failed'),
      transcoding: count('transcoding'),
      sourceBytes
    }
  };
}
