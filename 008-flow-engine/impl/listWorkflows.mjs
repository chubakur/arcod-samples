function view(row) {
  let steps = [];
  try {
    steps = JSON.parse(row.steps || '[]');
  } catch (err) {
    steps = [];
  }
  return {
    name: row.name,
    version: Number(row.version || 1),
    steps,
    createdAt: row.createdAt,
  };
}

export async function listWorkflows(input, io) {
  const page = await io.find('WorkflowRec', { limit: 200 });
  const items = (page.items || []).map(view);
  items.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  return { result: items };
}
