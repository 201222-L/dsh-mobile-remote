import { existsSync } from 'node:fs';
import { dirname, join, delimiter } from 'node:path';
import { execFile } from 'node:child_process';

export function npmFailure(error, stdout = '', stderr = '') {
  if (error.killed) return new Error('npm-timeout');
  let code;
  try { code = JSON.parse(stdout).error?.code; } catch { /* Read only a stable code, never registry diagnostics. */ }
  code ??= /^npm (?:ERR!|error) code ([A-Z0-9_]+)/m.exec(stderr)?.[1];
  const reasons = { E401: 'npm-auth-required', E403: 'npm-access-denied', E404: 'npm-package-not-found',
    ETARGET: 'npm-version-not-found', ENOTFOUND: 'npm-registry-unavailable', EAI_AGAIN: 'npm-registry-unavailable',
    ECONNREFUSED: 'npm-registry-unavailable', ENOTCACHED: 'npm-offline-cache-miss', ERESOLVE: 'npm-dependency-conflict',
    EINTEGRITY: 'npm-integrity-failed', EUNSUPPORTEDPROTOCOL: 'npm-package-spec-invalid',
    EINVALIDPACKAGENAME: 'npm-package-spec-invalid', ENOENT: 'npm-local-file-missing' };
  if (!reasons[code]) code = [...stderr.matchAll(/\b(E[A-Z][A-Z0-9_]{2,})\b/g)]
    .map(match => match[1]).find(candidate => reasons[candidate]);
  const reason = reasons[code];
  return new Error(reason ?? 'npm-command-failed');
}

export function npmCommand(args) {
  if (process.platform !== 'win32') return { file: 'npm', args };
  const roots = [process.env.npm_execpath, join(dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js'),
    ...(process.env.PATH ?? '').split(delimiter).map(path => join(path, 'node_modules/npm/bin/npm-cli.js'))];
  const cli = roots.find(path => path?.endsWith('npm-cli.js') && existsSync(path));
  if (!cli) throw new Error('npm-cli-unavailable');
  return { file: process.execPath, args: [cli, ...args] };
}

/** shell:false avoids .cmd quoting/injection; npm owns registry/auth configuration. */
export function runNpm(args, { cwd, signal, timeout = 120_000 } = {}) {
  const command = npmCommand(args);
  return new Promise((resolve, reject) => {
    execFile(command.file, command.args, { cwd, signal, timeout, windowsHide: true,
      maxBuffer: 2 * 1024 * 1024, env: { ...process.env, npm_config_update_notifier: 'false' } },
    (error, stdout, stderr) => {
      // Raw stderr may contain registry credentials. Keep it out of API/logs.
      if (error) reject(npmFailure(error, stdout, stderr));
      else resolve(stdout);
    });
  });
}
