import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import semver from 'semver';
import { npmCommand } from '../lib/package-command.js';

const exec = promisify(execFile);
const root = resolve(process.argv[2] ?? 'npm-dist');
const npm = async args => {
  const cmd = npmCommand(args);
  return exec(cmd.file, cmd.args, { windowsHide: true, timeout: 180_000, maxBuffer: 2 * 1024 * 1024 });
};
const metadata = async spec => {
  try { return JSON.parse((await npm(['view', spec, '--json'])).stdout); }
  catch (error) {
    let code;
    try { code = JSON.parse(error.stdout).error?.code; } catch { /* Require a definite registry 404. */ }
    if (code === 'E404') return null;
    throw new Error('npm-release-check-failed');
  }
};
for (const part of ['carrier', 'plugin']) {
  const directory = join(root, part);
  const pkg = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
  const tag = pkg.version.includes('-alpha') ? 'alpha' : pkg.version.includes('-rc') ? 'rc' : 'latest';
  const tagged = await metadata(`${pkg.name}@${tag}`);
  if (tagged && semver.gt(tagged.version, pkg.version)) throw new Error('npm-dist-tag-regression-refused');
  const packed = JSON.parse((await npm(['pack', directory, '--json', '--pack-destination', root])).stdout)[0];
  const existing = await metadata(`${pkg.name}@${pkg.version}`);
  if (existing) {
    if (existing.name !== pkg.name || existing.version !== pkg.version || existing.dist?.integrity !== packed.integrity) {
      throw new Error('published-version-content-conflict');
    }
    console.log(`${part}: exact published artifact verified; continuing interrupted release`);
    if (!tagged || tagged.version !== pkg.version) {
      await npm(['dist-tag', 'add', `${pkg.name}@${pkg.version}`, tag]);
    }
  } else {
    await npm(['publish', join(root, packed.filename), '--access', 'public', '--tag', tag, '--provenance']);
    console.log(`${part}: published`);
  }
}
