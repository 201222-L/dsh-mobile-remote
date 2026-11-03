import { readFile, writeFile, mkdir, cp, copyFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { verifyManifest } from '../lib/release-manifest.js';
import { verifyArtifact } from '../lib/release-updater.js';

const release = resolve(process.argv[2] ?? 'dist');
const out = resolve(process.argv[3] ?? 'npm-dist');
const manifest = JSON.parse(await readFile(join(release, 'release-manifest.json'), 'utf8'));
verifyManifest(manifest);
if (!manifest.npm) throw new Error('official-npm-scope-unconfigured');
for (const spec of Object.values(manifest.artifacts)) await verifyArtifact(join(release, spec.fileName), spec);
const carrier = join(out, 'carrier'), plugin = join(out, 'plugin');
await mkdir(carrier, { recursive: true }); await mkdir(plugin, { recursive: true });
for (const name of ['release-manifest.json', ...Object.values(manifest.artifacts).map(a => a.fileName)]) {
  await copyFile(join(release, name), join(carrier, name));
}
await writeFile(join(carrier, 'package.json'), JSON.stringify({
  name: manifest.npm.carrier, version: manifest.version, private: false,
  description: 'Paired DSH Remote signed release artifacts; no plugin runtime.',
  license: 'MIT', files: ['release-manifest.json', ...Object.values(manifest.artifacts).map(a => a.fileName)],
  publishConfig: { access: 'public' }, repository: `https://github.com/${manifest.repository}`,
}, null, 2) + '\n');
const pkg = JSON.parse(await readFile('package.json', 'utf8'));
for (const name of ['lib', 'docs', 'README.md', 'FAQ.md', 'CHANGELOG.md', 'CONTRIBUTING.md', 'LICENSE']) {
  await cp(name, join(plugin, name), { recursive: true });
}
delete pkg.devDependencies; delete pkg.scripts;
Object.assign(pkg, { name: manifest.npm.plugin, version: manifest.version,
  optionalDependencies: { [manifest.npm.carrier]: manifest.version },
  dshRelease: manifest, publishConfig: { access: 'public' },
  repository: `https://github.com/${manifest.repository}`,
});
await writeFile(join(plugin, 'package.json'), JSON.stringify(pkg, null, 2) + '\n');
console.log('Prepared exact plugin/carrier pair. Publish carrier before plugin.');
