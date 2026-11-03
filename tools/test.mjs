import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const files = readdirSync(new URL('../test/', import.meta.url))
  .filter(name => /\.test\.(?:mjs|js)$/.test(name)).sort()
  .map(name => `test/${name}`);
// Isolate HOME-based fixtures across files and keep timing-sensitive approval
// tests from competing with Git subprocess fixtures on shared CI runners.
const result = spawnSync(process.execPath,
  ['--test', '--test-concurrency=1', ...files], { stdio: 'inherit' });
process.exitCode = result.status ?? 1;
