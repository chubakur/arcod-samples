import http from 'node:http';

const port = Number(process.env.GEO_PORT || 9096);
let calls = 0;

const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }
  if (req.method === 'POST' && req.url === '/v1/reverse') {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      calls += 1;
      let body = {};
      try { body = JSON.parse(raw || '{}'); } catch {}
      const lat = Number(body.lat ?? 0).toFixed(3);
      const lng = Number(body.lng ?? 0).toFixed(3);
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ label: 'Mock district ' + lat + ',' + lng, calls }));
    });
    return;
  }
  if (req.url === '/stats') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ calls }));
    return;
  }
  res.writeHead(404, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ error: 'not found' }));
});

server.listen(port, () => console.log('geocoder mock on ' + port));
