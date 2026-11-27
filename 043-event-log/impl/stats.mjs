export async function stats(input, io) {
  const [streams, events, views, archives] = await Promise.all([
    io.count('Stream', {}),
    io.count('Event', {}),
    io.count('OrderView', {}),
    io.count('Archive', {}),
  ]);
  return {
    result: {
      streams: Number(streams) || 0,
      events: Number(events) || 0,
      views: Number(views) || 0,
      archives: Number(archives) || 0,
    },
  };
}
