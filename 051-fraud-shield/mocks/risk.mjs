// The external risk vendor for 051-fraud-shield, on the host at :9096.
// Deterministic by contract: the smoke test checks the fraud pipeline, not a
// model. Country XX is a high-risk country, DOWN is a vendor outage (503),
// an @suspicious.test email is a disposable address, a large amount is mildly
// suspicious. Everything else scores 5.
import http from 'node:http';

const PORT = Number(process.env.RISK_PORT || 9096);
const stats = { calls: 0, last: null };

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
  if (req.method !== 'POST' || req.url !== '/v1/score') return json(res, 404, { error: 'not found' });

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

  const country = String(claim.country || '').toUpperCase();
  const email = String(claim.email || '').toLowerCase();
  const amount = Number(claim.amount || 0);

  if (country === 'DOWN') {
    return json(res, 503, { error: 'risk vendor unavailable' });
  }
  if (country === 'XX') {
    return json(res, 200, { score: 88, reasons: 'high_risk_country,proxy_ip', model: 'mock-risk-v1' });
  }
  if (email.endsWith('@suspicious.test')) {
    return json(res, 200, { score: 75, reasons: 'disposable_email', model: 'mock-risk-v1' });
  }
  if (amount >= 40000) {
    return json(res, 200, { score: 40, reasons: 'large_amount', model: 'mock-risk-v1' });
  }
  return json(res, 200, { score: 5, reasons: '', model: 'mock-risk-v1' });
});

server.listen(PORT, '0.0.0.0', () => console.log('mock risk vendor on ' + PORT));
