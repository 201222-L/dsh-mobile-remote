import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { verifyManifest } from '../lib/release-manifest.js';
import { verifyArtifact } from '../lib/release-updater.js';

const directory = process.argv[2] ?? 'release-dist';
const manifest = JSON.parse(await readFile(join(directory, 'release-manifest.json'), 'utf8'));
verifyManifest(manifest);
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
if (manifest.commit !== commit) throw new Error('release-artifact-commit-disagrees');
if (process.env.TAG && manifest.tag !== process.env.TAG) throw new Error('release-tag-disagrees');
const expected = ['release-manifest.json', ...Object.values(manifest.artifacts).map(spec => spec.fileName)].sort();
if (JSON.stringify((await readdir(directory)).sort()) !== JSON.stringify(expected)) throw new Error('release-artifact-set-invalid');
for (const spec of Object.values(manifest.artifacts)) await verifyArtifact(join(directory, spec.fileName), spec);
console.log(`Verified paired artifacts: ${manifest.tag} (${manifest.commit})`);
