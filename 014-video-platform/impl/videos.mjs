// Listing is a page, not a dump: the default limit keeps a big library cheap.
export async function videos(input, io) {
  const limit = Number(input.limit || 20);
  const page = await io.find('Video', { order: 'createdAt', limit: Number.isFinite(limit) ? limit : 20 });
  return { result: page.items || [] };
}
