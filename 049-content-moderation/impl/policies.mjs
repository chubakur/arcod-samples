// The policy list is readable by every signed-in user: authors can see the
// rules they are judged by, and the history shows which version was active.
export async function policies(input, io) {
  const page = await io.find('Policy', { order: 'version desc', limit: 100 });
  return { result: page.items || [] };
}
