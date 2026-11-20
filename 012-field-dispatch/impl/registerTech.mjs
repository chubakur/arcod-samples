export async function registerTech(input, io) {
  const name = String(input.name || '').trim();
  const city = String(input.city || '').trim();
  const skills = (Array.isArray(input.skills) ? input.skills : [])
    .map((s) => String(s || '').trim().toLowerCase())
    .filter(Boolean);

  if (!name || !city || skills.length === 0) return { error: 'Invalid' };

  const tech = {
    id: await io.new(),
    name,
    city,
    // list<string> columns are not insertable into mysql JSON yet (issue #30),
    // so the model stores a comma-separated string and splits it in the body.
    skills: skills.join(','),
    active: true,
    load: 0,
  };
  await io.insert('Tech', tech);
  return { result: tech };
}
