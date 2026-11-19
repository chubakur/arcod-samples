export async function getWorkflow(input, io) {
  const name = String(input.name == null ? '' : input.name).trim();
  const row = name ? await io.fetch('WorkflowRec', name) : null;
  if (!row) return { error: 'NotFound' };

  let steps = [];
  try {
    steps = JSON.parse(row.steps || '[]');
  } catch (err) {
    steps = [];
  }

  return {
    result: {
      name: row.name,
      version: Number(row.version || 1),
      steps,
      createdAt: row.createdAt,
    },
  };
}
