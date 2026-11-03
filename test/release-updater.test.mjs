import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createHash } from 'node:crypto';
import { mkdtemp, writeFile, readFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { signManifest, verifyManifest, manifestDigest } from '../lib/release-manifest.js';
import { ReleaseUpdater } from '../lib/release-updater.js';
import { applyPreparedUpdate } from '../lib/update-helper.js';

const pair = generateKeyPairSync('ed25519');
const seed = pair.privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('base64url');
const pub = pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url');
const keys = { test: pub };
const plugin = Buffer.from('plugin fixture'), apk = Buffer.from('APK fixture');
const spec = (bytes, fileName) => ({ size: bytes.length, fileName, sha256: createHash('sha256').update(bytes).digest('hex') });
function release({ version = '3.2.4', channel = 'stable' } = {}) {
  return signManifest({ schemaVersion: 1, repository: '201222-L/dsh-mobile-remote',
    version, tag: `v${version}`, channel, commit: 'a'.repeat(40),
    npm: { plugin: '@official/dsh-mobile-remote', carrier: '@official/dsh-mobile-remote-app' },
    artifacts: { plugin: spec(plugin, 'plugin.tgz'), app: { ...spec(apk, 'app.apk'),
      versionName: version, versionCode: 32, packageName: 'com.dsh.remote', certificateSha256: 'f'.repeat(64) } },
  }, { keyId: 'test', seed });
}
const base = 'https://github.com/201222-L/dsh-mobile-remote/releases/download/v3.2.4/';
function github(manifest, { corrupt = false } = {}) {
  return async url => {
    if (String(url).endsWith('/latest')) return Response.json({ tag_name: manifest.tag, assets:
      ['release-manifest.json', 'plugin.tgz', 'app.apk'].map(name => ({ name, browser_download_url: base + name })) });
    if (String(url).endsWith('release-manifest.json')) return Response.json(manifest);
    return new Response(String(url).endsWith('plugin.tgz') ? plugin : corrupt ? 'wrong' : apk);
  };
}
async function fixture(t, options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-update-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const manifest = release();
  const updater = new ReleaseUpdater({ currentVersion: '3.2.3', directory, keys,
    fetchImpl: github(manifest), ...options });
  return { updater, directory, manifest };
}

test('check stays read-only with respect to installation and stages an exact signed pair', async t => {
  let installed = 0;
  const { updater, directory, manifest } = await fixture(t, { config: { profileDirectory: '/configured-profile' },
    prepareInstall: async () => { installed++; } });
  const status = await updater.check();
  assert.equal(status.candidate.available, true); assert.equal(installed, 0);
  await assert.rejects(updater.install({ digest: status.candidate.digest }), /confirmation-required/);
  await updater.stage(status.candidate.digest);
  assert.equal(installed, 0);
  const stage = join(directory, manifestDigest(manifest));
  assert.deepEqual(await readFile(join(stage, 'app.apk')), apk);
  await assert.rejects(updater.install({ digest: status.candidate.digest, confirmed: true, hasRunning: true }), /running-tasks/);
  await updater.install({ digest: status.candidate.digest, confirmed: true });
  assert.equal(installed, 1); assert.equal(updater.status().restartMode, 'manual');
});

test('tampered metadata, wrong signatures and traversal artifact names fail closed', () => {
  const valid = release(); assert.ok(verifyManifest(valid, { keys }).digest);
  assert.throws(() => verifyManifest({ ...valid, version: '9.9.9' }, { keys }));
  assert.throws(() => verifyManifest(valid, { keys: {} }), /signature/);
  const bad = structuredClone(valid); bad.artifacts.app.fileName = '../outside.apk';
  assert.throws(() => verifyManifest(bad, { keys }), /artifact-invalid/);
});

test('partial/corrupt artifacts cannot reach staged or installation state', async t => {
  const manifest = release();
  const { updater, directory } = await fixture(t, { fetchImpl: github(manifest, { corrupt: true }) });
  const status = await updater.check();
  await assert.rejects(updater.stage(status.candidate.digest), /artifact-/);
  await assert.rejects(readFile(join(directory, status.candidate.digest, 'release-manifest.json')));
});

test('restart retains staged manifest, blocks old plugin from serving APK, then confirms active version', async t => {
  const { updater, directory } = await fixture(t);
  const status = await updater.check(); await updater.stage(status.candidate.digest);
  const old = new ReleaseUpdater({ currentVersion: '3.2.3', directory, keys });
  await assert.rejects(old.appArtifact(), /plugin-version-not-active/);
  const next = new ReleaseUpdater({ currentVersion: '3.2.4', directory, keys });
  const artifact = await next.appArtifact();
  assert.equal(artifact.spec.versionCode, 32);
  assert.deepEqual(await readFile(artifact.path), apk);
  assert.equal(next.status().phase, 'plugin-ready');
});

test('npm identity must be an explicitly configured scoped package; no fallback to GitHub', async t => {
  let calls = 0, fetches = 0;
  const { updater } = await fixture(t, { config: { source: 'npm', npmPackage: 'dsh-mobile-remote' },
    npm: async () => { calls++; }, fetchImpl: async () => { fetches++; } });
  await assert.rejects(updater.check(), /unconfigured/);
  assert.equal(calls, 0); assert.equal(fetches, 0);
});

test('npm check uses host npm configuration and accepts only its own signed identity', async t => {
  const manifest = release(); const calls = [];
  const { updater } = await fixture(t, { config: { source: 'npm', npmPackage: manifest.npm.plugin },
    npm: async args => { calls.push(args); return JSON.stringify({ name: manifest.npm.plugin, version: manifest.version, dshRelease: manifest }); } });
  assert.equal((await updater.check()).candidate.version, '3.2.4');
  assert.deepEqual(calls[0], ['view', '@official/dsh-mobile-remote@latest', '--json']);
});

test('a candidate digest cannot be replaced between review and installation', async t => {
  const { updater } = await fixture(t); await updater.check();
  await assert.rejects(updater.stage('0'.repeat(64)), /candidate-changed/);
});

test('downgrades and crossing release channels are rejected', async t => {
  const { updater } = await fixture(t, { currentVersion: '3.3.0' });
  await assert.rejects(updater.check(), /downgrade/);
  const other = await fixture(t, { config: { channel: 'rc' } });
  await assert.rejects(other.updater.check());
});

test('helper restores package and lockfile when npm installation fails', async t => {
  const { updater, directory, manifest } = await fixture(t);
  const status = await updater.check(); await updater.stage(status.candidate.digest);
  const stage = join(directory, status.candidate.digest), profile = join(directory, 'profile');
  await mkdir(profile);
  await writeFile(join(profile, 'package.json'), '{"name":"profile"}');
  await writeFile(join(profile, 'package-lock.json'), '{"lockfileVersion":3}');
  const path = join(stage, 'install-request.json');
  await writeFile(path, JSON.stringify({ schemaVersion: 1, hostPid: process.pid + 1,
    stage, profile, version: manifest.version, restart: null }));
  const calls = [];
  await assert.rejects(applyPreparedUpdate(path, { keys, isAlive: () => false, delay: async () => {},
    npm: async args => { calls.push(args); if (args[0] === 'install') {
      await writeFile(join(profile, 'package.json'), '{"broken":true}'); throw new Error('npm-command-failed');
    } } }), /npm-command-failed/);
  assert.deepEqual(calls.map(args => args[0]), ['install', 'ci']);
  assert.equal(await readFile(join(profile, 'package.json'), 'utf8'), '{"name":"profile"}');
  assert.equal(JSON.parse(await readFile(join(stage, 'install-journal.json'))).phase, 'rolled-back');
});

test('a previously observed version cannot silently change contents', async t => {
  const { updater, directory, manifest } = await fixture(t); await updater.check();
  const changed = structuredClone(manifest);
  delete changed.signatures;
  changed.artifacts.app.sha256 = '1'.repeat(64);
  const signed = signManifest(changed, { keyId: 'test', seed });
  const restarted = new ReleaseUpdater({ currentVersion: '3.2.3', directory, keys, fetchImpl: github(signed) });
  await assert.rejects(restarted.check(), /version-content-changed/);
});
