import { existsSync } from 'node:fs';
import { dirname, join, delimiter } from 'node:path';
import { execFile } from 'node:child_process';

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
    (error, stdout) => {
      // Raw stderr may contain registry credentials. Keep it out of API/logs.
      if (error) reject(new Error(error.killed ? 'npm-timeout' : 'npm-command-failed'));
      else resolve(stdout);
    });
  });
}
