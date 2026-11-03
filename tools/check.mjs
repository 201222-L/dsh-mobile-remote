import { spawnSync } from 'node:child_process';
for (const script of ['tools/timeline-contract-check.mjs', 'tools/account-usage-check.mjs', 'tools/account-usage-adversarial-check.mjs']) {
  const result = spawnSync(process.execPath, [script], { stdio: 'inherit' });
  if (result.status !== 0) process.exit(result.status ?? 1);
}
