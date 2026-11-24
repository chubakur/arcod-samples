export async function stats(input, io) {
  const devices = await io.count('Device', { where: {} });
  const readings = await io.count('Reading', { where: {} });
  const rules = await io.count('Rule', { where: { active: true } });
  const openAlerts = await io.count('Alert', { where: { status: 'open' } });
  return { result: { devices, readings, rules, openAlerts } };
}
