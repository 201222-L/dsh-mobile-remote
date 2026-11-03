import { readFile, writeFile, mkdir, copyFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { signManifest, validPackage, validVersion, verifyManifest, trustedReleaseKeys } from '../lib/release-manifest.js';

const args = Object.fromEntries(process.argv.slice(2).reduce((items, arg, i, list) =>
  arg.startsWith('--') ? [...items, [arg.slice(2), list[i + 1]]] : items, []));
const pkg = JSON.parse(await readFile('package.json', 'utf8'));
const pub = await readFile('dsh-mobile-app/pubspec.yaml', 'utf8');
const match = /^version:\s*(\S+)\+(\d+)\s*$/m.exec(pub);
if (!match || match[1] !== pkg.version || !validVersion(pkg.version)) throw new Error('release-versions-disagree');
if (args.tag && args.tag !== `v${pkg.version}`) throw new Error('release-tag-disagrees');
if (!args.apk || !args.plugin || !args.certificate) throw new Error('usage: --apk FILE --plugin FILE --certificate SHA256 [--out DIR]');
const out = resolve(args.out ?? 'dist');
await mkdir(out, { recursive: true });
const info = async (path, fileName) => ({ fileName, size: (await stat(path)).size,
  sha256: createHash('sha256').update(await readFile(path)).digest('hex') });
const pluginFile = `dsh-mobile-remote-${pkg.version}.tgz`;
const apkFile = `DSH-Remote-v${pkg.version}.apk`;
const payload = {
  schemaVersion: 1, repository: '201222-L/dsh-mobile-remote', version: pkg.version,
  tag: `v${pkg.version}`, channel: pkg.version.includes('-alpha') ? 'alpha' : pkg.version.includes('-rc') ? 'rc' : 'stable',
  commit: execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(),
  artifacts: {
    plugin: await info(args.plugin, pluginFile),
    app: { ...await info(args.apk, apkFile), versionName: pkg.version,
      versionCode: Number(match[2]), packageName: 'com.dsh.remote',
      certificateSha256: args.certificate.replaceAll(':', '').toLowerCase() },
  },
};
const scope = process.env.OFFICIAL_NPM_SCOPE;
if (scope) {
  const plugin = `${scope}/dsh-mobile-remote`, carrier = `${scope}/dsh-mobile-remote-app`;
  if (!validPackage(plugin) || !validPackage(carrier)) throw new Error('official-npm-scope-invalid');
  payload.npm = { plugin, carrier };
}
const manifest = signManifest(payload, { keyId: process.env.RELEASE_KEY_ID ?? 'dsh-release-2026', seed: process.env.RELEASE_SIGNING_SEED });
verifyManifest(manifest, { keys: trustedReleaseKeys });
// Never overwrite a version with different bytes. Run in a new version directory.
const manifestPath = join(out, 'release-manifest.json');
try {
  const previous = JSON.parse(await readFile(manifestPath, 'utf8'));
  if (JSON.stringify(previous) !== JSON.stringify(manifest)) throw new Error('release-version-already-exists');
} catch (error) { if (error.code !== 'ENOENT') throw error; }
for (const [src, dest] of [[args.plugin, pluginFile], [args.apk, apkFile]]) {
  if (resolve(src) !== join(out, dest)) await copyFile(src, join(out, dest));
}
await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + '\n', { flag: 'w' });
console.log(`Prepared ${pkg.version} / App build ${match[2]}`);
