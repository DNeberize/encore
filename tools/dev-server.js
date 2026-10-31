// Live development server for the page script and block list. In the app,
// ••• → Live Script Server → type the address printed below. The app then
// loads Encore/Resources/encore.js and blocklist.json from this computer and
// reloads its pages each time you save one; page console output shows here.
//
//   npm run dev            (set PORT to use another port than 8787)

'use strict';
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PORT = Number(process.env.PORT) || 8787;
const DIR = path.join(__dirname, '..', 'Encore', 'Resources');
const FILES = { 'encore.js': 'application/javascript', 'blocklist.json': 'application/json' };
const HOLD_MS = 25000;

const color = (code) => (text) => (process.stdout.isTTY ? `\x1b[${code}m${text}\x1b[0m` : text);
const red = color(31), yellow = color(33), green = color(32), dim = color(2), bold = color(1);
const time = () => dim(new Date().toLocaleTimeString());
const say = (text) => console.log(`${time()} ${text}`);

// ---------------------------------------------------------------------------
// File versions: the app long-polls /changes and refetches when this moves
// ---------------------------------------------------------------------------

function readVersion() {
  return Object.keys(FILES).map((name) => {
    try {
      const stat = fs.statSync(path.join(DIR, name));
      return `${stat.mtimeMs}-${stat.size}`;
    } catch (e) {
      return 'missing';
    }
  }).join('.');
}

function checkFiles() {
  try {
    JSON.parse(fs.readFileSync(path.join(DIR, 'blocklist.json'), 'utf8'));
  } catch (e) {
    say(red(`blocklist.json is not valid JSON: ${e.message}`));
  }
  try {
    new Function(fs.readFileSync(path.join(DIR, 'encore.js'), 'utf8'));
  } catch (e) {
    say(red(`encore.js has a syntax error: ${e.message}`));
  }
}

let version = readVersion();
let waiting = new Set();

// Waits until a save has settled (two equal reads in a row) before telling the app.
let candidate = version;
setInterval(() => {
  const next = readVersion();
  if (next !== candidate) { candidate = next; return; }
  if (next === version) return;
  version = next;
  checkFiles();
  say(waiting.size ? green('Saved, reloading the app') : yellow('Saved, but no app is connected'));
  for (const res of waiting) res.end(version);
  waiting.clear();
}, 200);

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function logFromApp(entry) {
  const where = dim(`[${entry.page || 'app'}]`);
  const text = String(entry.text || '');
  if (entry.level === 'error') say(`${where} ${red(text)}`);
  else if (entry.level === 'warn') say(`${where} ${yellow(text)}`);
  else say(`${where} ${text}`);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  res.setHeader('Cache-Control', 'no-store');

  if (req.method === 'GET' && url.pathname === '/changes') {
    if (url.searchParams.get('since') !== version) return res.end(version);
    waiting.add(res);
    const timer = setTimeout(() => { waiting.delete(res); res.end(version); }, HOLD_MS);
    res.on('close', () => { clearTimeout(timer); waiting.delete(res); });
    return;
  }

  const name = url.pathname.slice(1);
  if (req.method === 'GET' && FILES[name]) {
    fs.readFile(path.join(DIR, name), (err, data) => {
      if (err) { res.statusCode = 404; return res.end(); }
      if (name === 'encore.js') say(`App loaded ${name} ${dim(`(${req.socket.remoteAddress})`)}`);
      res.setHeader('Content-Type', FILES[name]);
      res.end(data);
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/log') {
    let body = '';
    req.on('data', (chunk) => { if (body.length < 100000) body += chunk; });
    req.on('end', () => {
      try { logFromApp(JSON.parse(body)); } catch (e) {}
      res.end();
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/') {
    res.setHeader('Content-Type', 'text/plain; charset=utf-8');
    return res.end('Encore live script server. Type this address in the app: ••• → Live Script Server.\n');
  }

  res.statusCode = 404;
  res.end();
});

server.on('error', (e) => {
  console.error(red(e.code === 'EADDRINUSE' ? `Port ${PORT} is in use. Stop the other server or set PORT to another number.` : e.message));
  process.exit(1);
});

server.listen(PORT, '0.0.0.0', () => {
  // Virtual adapters (WSL, Hyper-V, VPNs, VMs) can't be reached from the phone: list them last.
  const isVirtual = (name) => /vEthernet|WSL|Hyper-V|VirtualBox|VMware|Loopback|docker|tailscale|zerotier|vpn/i.test(name);
  const addresses = Object.entries(os.networkInterfaces())
    .flatMap(([name, list]) => (list || [])
      .filter((a) => a.family === 'IPv4' && !a.internal)
      .map((a) => ({ name, address: `${a.address}:${PORT}`, virtual: isVirtual(name) })))
    .sort((a, b) => a.virtual - b.virtual);

  console.log(bold('\nEncore live script server\n'));
  if (addresses.length) {
    console.log('In the app: ••• → Live Script Server, then type:');
    for (const a of addresses) {
      console.log(a.virtual ? dim(`  ${a.address}  ${a.name} (virtual, won't work)`) : `  ${green(a.address)}  ${dim(a.name)}`);
    }
    if (addresses.length > 1) console.log(dim('  Use the one on the network the iPhone is on (Wi-Fi, or the iPhone hotspot).'));
  } else {
    console.log(yellow('No network address found. Connect this computer to Wi-Fi.'));
  }
  console.log(dim(`\nServing ${path.relative(process.cwd(), DIR) || DIR}. Save a file and the app reloads. Ctrl+C to stop.\n`));
  checkFiles();
});
