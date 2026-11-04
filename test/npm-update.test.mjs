import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash, generateKeyPairSync } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { c as tar } from 'tar';
import { officialNpm, npmReleasePackages, installedPluginDependency } from '../lib/official-npm.js';
import { ReleaseUpdater } from '../lib/release-updater.js';
import { applyPreparedUpdate, preparePluginInstall } from '../lib/update-helper.js';
import { runNpm, npmFailure } from '../lib/package-command.js';
import { signManifest } from '../lib/release-manifest.js';

test('official npm names are explicit; scoped profiles retain the configured dependency key', () => {
  assert.deepEqual(npmReleasePackages(officialNpm.scope), { plugin: officialNpm.plugin, carrier: officialNpm.carrier });
  assert.throws(() => npmReleasePackages('dsh-mobile-remote'), /scope-invalid/);
  const manifest = { npm: { plugin: officialNpm.plugin } };
  assert.equal(installedPluginDependency({ dependencies: { [officialNpm.plugin]: '3.2.3' } }, manifest), officialNpm.plugin);
  assert.equal(installedPluginDependency({ dependencies: { [officialNpm.plugin]: '3.2.3' } }, {}), officialNpm.plugin,
    'A GitHub-only release must also preserve an already-scoped installation');
  assert.equal(installedPluginDependency({ dependencies: { 'dsh-mobile-remote': 'file:old.tgz' } }, manifest), 'dsh-mobile-remote');
  assert.throws(() => installedPluginDependency({ dependencies: {
    [officialNpm.plugin]: '3.2.3', 'dsh-mobile-remote': 'file:old.tgz',
  } }, manifest), /ambiguous-plugin-dependency/);
});

test('npm errors distinguish authentication, missing packages and registry failure without exposing diagnostics', () => {
  for (const [code, expected] of [['E401', 'npm-auth-required'], ['E403', 'npm-access-denied'],
    ['E404', 'npm-package-not-found'], ['ETARGET', 'npm-version-not-found'], ['ENOTFOUND', 'npm-registry-unavailable'],
    ['UNKNOWN', 'npm-command-failed']]) {
    const output = JSON.stringify({ error: { code, detail: 'Bearer private-fixture-secret' } });
    assert.equal(npmFailure({}, output).message, expected);
    assert.equal(npmFailure({}, '', `npm error code ${code}\nAuthorization: private-fixture-secret`).message, expected);
  }
  assert.equal(npmFailure({ killed: true }).message, 'npm-timeout');
});

test('ambiguous dependency identity is refused before preparing a restart or spawning a helper', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-npm-ambiguous-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const profile = join(root, 'profile'), stage = join(root, 'stage');
  await mkdir(profile); await mkdir(stage);
  await writeFile(join(profile, 'package-lock.json'), '{}');
  await writeFile(join(profile, 'package.json'), JSON.stringify({ dependencies: {
    [officialNpm.plugin]: '3.2.3', 'dsh-mobile-remote': 'file:old.tgz',
  } }));
  await assert.rejects(preparePluginInstall({ manifest: { npm: officialNpm }, stage, profile, form: 'desktop', config: {} }),
    /ambiguous-plugin-dependency/);
  await assert.rejects(stat(join(stage, 'install.lock')), { code: 'ENOENT' });
  await assert.rejects(stat(join(stage, 'install-request.json')), { code: 'ENOENT' });
});

test('real npm honors scoped registry/auth, stages a signed carrier and updates the scoped profile offline', async t => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-npm-e2e-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, 'source'), profile = join(root, 'profile'), packageDir = join(source, 'package');
  await mkdir(join(packageDir, 'lib'), { recursive: true });
  await mkdir(profile);
  const version = '3.2.4', identity = npmReleasePackages('@device-fixture');
  await writeFile(join(packageDir, 'package.json'), JSON.stringify({ name: 'dsh-mobile-remote', version, type: 'module', main: 'lib/index.js' }));
  await writeFile(join(packageDir, 'lib/index.js'), 'export const installedFromSignedArtifact = true;\n');
  const pluginPath = join(root, 'plugin.tgz');
  await tar({ cwd: source, file: pluginPath, gzip: true, portable: true }, ['package']);
  const plugin = await readFile(pluginPath), app = Buffer.from('synthetic APK; never installed on a device');
  const pair = generateKeyPairSync('ed25519');
  const seed = pair.privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('base64url');
  const keys = { fixture: pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url') };
  const spec = (data, fileName) => ({ fileName, size: data.length, sha256: createHash('sha256').update(data).digest('hex') });
  const manifest = signManifest({ schemaVersion: 1, repository: '201222-L/dsh-mobile-remote', version,
    tag: `v${version}`, channel: 'stable', commit: 'b'.repeat(40), npm: identity,
    artifacts: { plugin: spec(plugin, 'plugin.tgz'), app: { ...spec(app, 'app.apk'),
      packageName: 'com.dsh.remote', versionName: version, versionCode: 35, certificateSha256: 'c'.repeat(64) } },
  }, { keyId: 'fixture', seed });
  const carrierRoot = join(root, 'carrier'), carrierDir = join(carrierRoot, 'package');
  await mkdir(carrierDir, { recursive: true });
  await writeFile(join(carrierDir, 'package.json'), JSON.stringify({ name: identity.carrier, version }));
  await writeFile(join(carrierDir, 'release-manifest.json'), JSON.stringify(manifest));
  await writeFile(join(carrierDir, 'plugin.tgz'), plugin);
  await writeFile(join(carrierDir, 'app.apk'), app);
  const carrierPath = join(root, 'carrier.tgz');
  await tar({ cwd: carrierRoot, file: carrierPath, gzip: true, portable: true }, ['package']);
  const carrier = await readFile(carrierPath);
  const requests = [], registryToken = 'synthetic-registry-credential';
  const server = createServer((req, res) => {
    requests.push({ path: decodeURIComponent(req.url), authenticated: req.headers.authorization === `Bearer ${registryToken}` });
    if (req.headers.authorization !== `Bearer ${registryToken}`) { res.writeHead(401); res.end(); return; }
    if (req.url === '/carrier.tgz') { res.writeHead(200); res.end(carrier); return; }
    const name = decodeURIComponent(req.url).split('?')[0].replace(/^\//, '');
    if (![identity.plugin, identity.carrier].includes(name)) { res.writeHead(404); res.end('{}'); return; }
    const item = { name, version, ...(name === identity.plugin ? { dshRelease: manifest } : {}),
      dist: { tarball: `http://127.0.0.1:${server.address().port}/carrier.tgz`,
        integrity: `sha512-${createHash('sha512').update(carrier).digest('base64')}`,
        shasum: createHash('sha1').update(carrier).digest('hex') } };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ name, 'dist-tags': { latest: version }, versions: { [version]: item } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const port = server.address().port;
  await writeFile(join(profile, '.npmrc'), [
    'registry=http://127.0.0.1:1/',
    `@device-fixture:registry=http://127.0.0.1:${port}/`,
    `//127.0.0.1:${port}/:_authToken=${registryToken}`,
    `cache=${join(root, 'npm-cache').replaceAll('\\', '/')}`,
    'audit=false', 'fund=false', 'fetch-retries=0',
  ].join('\n'));
  const originalProfile = JSON.stringify({ name: 'isolated-npm-profile', version: '1.0.0',
    dependencies: { [identity.plugin]: '3.2.3' } });
  await writeFile(join(profile, 'package.json'), originalProfile);
  await writeFile(join(profile, 'package-lock.json'), JSON.stringify({ name: 'isolated-npm-profile', lockfileVersion: 3, packages: {} }));
  const commands = [], npm = async (args, options) => {
    commands.push(args[0]);
    return runNpm(args[0] === 'install' ? [args[0], '--offline', ...args.slice(1)] : args, options);
  };
  const updater = new ReleaseUpdater({ currentVersion: '3.2.3', directory: join(root, 'updates'), keys,
    config: { source: 'npm', npmPackage: identity.plugin, profileDirectory: profile }, npm,
    fetchImpl: async () => { throw new Error('must-not-fall-back-to-github'); } });
  const available = await updater.check();
  assert.equal(available.candidate.version, version);
  assert.deepEqual(commands, ['view']);
  assert.equal(await readFile(join(profile, 'package.json'), 'utf8'), originalProfile);
  const staged = await updater.stage(available.candidate.digest);
  assert.equal(staged.phase, 'staged');
  assert.deepEqual(commands, ['view', 'pack']);
  const stage = join(root, 'updates', available.candidate.digest);
  assert.deepEqual(await readFile(join(stage, 'app.apk')), app);
  assert.ok(requests.length >= 3 && requests.every(r => r.authenticated));
  assert.ok(requests.every(r => r.path.startsWith('/@device-fixture/') || r.path === '/carrier.tgz'));
  const request = join(stage, 'install-request.json');
  await writeFile(request, JSON.stringify({ schemaVersion: 1, hostPid: process.pid + 1, stage, profile, version, restart: null }));
  await applyPreparedUpdate(request, { npm, keys, isAlive: () => false, delay: async () => {} });
  const installedProfile = JSON.parse(await readFile(join(profile, 'package.json'), 'utf8'));
  assert.ok(installedProfile.dependencies[identity.plugin].startsWith('file:'));
  assert.equal(installedProfile.dependencies['dsh-mobile-remote'], undefined, 'Do not leave the scoped plugin unchanged and add an unused legacy copy');
  const installed = JSON.parse(await readFile(join(profile, 'node_modules', identity.plugin, 'package.json'), 'utf8'));
  assert.equal(installed.version, version);
  const resolved = createRequire(join(profile, 'package.json')).resolve(identity.plugin);
  assert.equal((await import(pathToFileURL(resolved).href)).installedFromSignedArtifact, true);
  assert.equal(await readFile(join(profile, 'node_modules', identity.plugin, 'lib/index.js'), 'utf8'),
    'export const installedFromSignedArtifact = true;\n');
  assert.equal(JSON.parse(await readFile(join(stage, 'install-journal.json'), 'utf8')).phase, 'awaiting-start');
  const state = await readFile(join(root, 'updates/state.json'), 'utf8');
  assert.ok(!state.includes(registryToken));
});
