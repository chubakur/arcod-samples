// The progress view joins the control row with the rendition rows the consumer
// wrote: the client polls this instead of guessing from a status string.
export async function video(input, io) {
  const id = String(input.id || '');
  if (!id) return { error: 'NotFound' };
  const found = await io.fetch('Video', id);
  if (!found) return { error: 'NotFound' };
  const renditions = await io.find('Rendition', { where: { videoId: id }, limit: 10 });
  const items = renditions.items || [];
  return { result: { video: found, renditions: items, ready: items.length, total: 2 } };
}
