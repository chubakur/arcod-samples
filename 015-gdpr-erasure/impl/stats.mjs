export async function stats(input, io) {
  const found = await io.find('ErasureRequest', { where: {}, limit: 1000 });
  const rows = (found && found.items) || [];
  const out = { total: rows.length, pending: 0, erasing: 0, erased: 0, certified: 0, failed: 0, rowsErased: 0 };
  for (const row of rows) {
    if (Object.prototype.hasOwnProperty.call(out, row.state)) out[row.state] += 1;
    out.rowsErased += Number(row.rowsDeleted || 0);
  }
  return { result: out };
}
