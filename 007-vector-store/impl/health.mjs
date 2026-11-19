// Liveness plus a cheap fact: how many collections exist. The count is a
// bounded scan (500), not a cached counter that can drift.

export async function health(input, io) {
  let count = 0;
  let cursor = null;
  do {
    const query = { limit: 200 };
    if (cursor) query.cursor = cursor;
    const page = await io.find('Collection', query);
    count += (page.items || []).length;
    if (count >= 500) break;
    cursor = page.next || null;
  } while (cursor);

  return { result: { ok: true, collections: count } };
}
