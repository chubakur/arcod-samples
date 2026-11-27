// The external carrier (3PL) for 052-warehouse-fulfillment, on the host at
// :9094. Deterministic: every accepted shipment gets a tracking number and a
// printable label; carrier "down" answers 503 so the retry path and the dead
// letter can be exercised.
import http from 'node:http';

const PORT = Number(process.env.CARRIER_PORT || 9094);
const stats = { calls: 0, accepted: 0, rejected: 0, last: null };

function json(res, status, value) {
  const body = JSON.stringify(value);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch (error) { reject(error); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') return json(res, 200, { ok: true });
  if (req.method === 'GET' && req.url === '/stats') return json(res, 200, stats);
  if (req.method !== 'POST' || req.url !== '/v1/shipments') return json(res, 404, { error: 'not found' });

  let body;
  try {
    body = await readBody(req);
  } catch (error) {
    return json(res, 400, { error: 'bad json' });
  }
  let claim = {};
  try {
    claim = JSON.parse(String(body.payload || '{}'));
  } catch (error) {
    claim = {};
  }
  stats.calls += 1;
  stats.last = claim;

  if (String(claim.carrier || '').toLowerCase() === 'down') {
    stats.rejected += 1;
    return json(res, 503, { error: 'carrier network unavailable' });
  }

  stats.accepted += 1;
  const seq = String(stats.accepted).padStart(4, '0');
  const tracking = String(claim.carrier || 'post').toUpperCase() + '-TRK-' + seq;
  const label = [
    'SHIP TO: ' + String(claim.customer || ''),
    'ADDRESS: ' + String(claim.address || ''),
    'ORDER:   ' + String(claim.orderId || ''),
    'UNITS:   ' + String(claim.units || 0),
    'TRACKING:' + tracking,
  ].join('\n');
  return json(res, 200, { tracking, label, service: 'ground' });
});

server.listen(PORT, '0.0.0.0', () => console.log('mock carrier on ' + PORT));
