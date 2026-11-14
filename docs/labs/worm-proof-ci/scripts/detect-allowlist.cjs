#!/usr/bin/env node
// Print the install-script packages in a lockfile, one per line: the per-project allowlist.
// npm sets `hasInstallScript: true` for any package with preinstall/install/postinstall, which
// is exactly what --ignore-scripts skips and what would have to be re-enabled by name.
const lock = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const names = new Set();
for (const [k, v] of Object.entries(lock.packages || {})) {
  if (v.hasInstallScript && k) names.add(k.replace(/^.*node_modules\//, ''));
}
process.stdout.write([...names].sort().map((n) => n + '\n').join(''));
