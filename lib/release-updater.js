import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync } from 'node:fs';
import { mkdir, readFile, writeFile, rename, rm, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { x as extract } from 'tar';
import semver from 'semver';
import { verifyManifest, validPackage } from './release-manifest.js';
import { runNpm } from './package-command.js';

const repository = '201222-L/dsh-mobile-remote';
const safeState = error => /^[a-z][a-z0-9-]{0,80}$/.test(error?.message ?? '') ? error.message : 'update-operation-failed';
const writeJson = async (path, value) => {
  const tmp = `${path}.${randomUUID()}.tmp`;
  await writeFile(tmp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  await rename(tmp, path);
};

export async function verifyArtifact(path, spec) {
  if ((await stat(path)).size !== spec.size) throw new Error('artifact-size-mismatch');
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  if (hash.digest('hex') !== spec.sha256) throw new Error('artifact-hash-mismatch');
}

/** Downloads never buffer an APK in memory. Redirects remain HTTPS. */
export async function downloadArtifact(url, dest, spec, { fetchImpl = fetch, signal } = {}) {
  if (!url.startsWith('https://')) throw new Error('artifact-url-invalid');
  const response = await fetchImpl(url, { signal });
  if (!response.ok || !response.body || (response.url && !response.url.startsWith('https://'))) {
    throw new Error('artifact-download-failed');
  }
  let size = 0;
  const hash = createHash('sha256');
  const check = new Transform({ transform(chunk, _, done) {
    size += chunk.length;
    if (size > spec.size) return done(new Error('artifact-size-mismatch'));
    hash.update(chunk); done(null, chunk);
  } });
  const tmp = `${dest}.part`;
  try {
    await pipeline(Readable.fromWeb(response.body), check, createWriteStream(tmp, { flags: 'wx' }), { signal });
    if (size !== spec.size || hash.digest('hex') !== spec.sha256) throw new Error('artifact-hash-mismatch');
    await rename(tmp, dest);
  } finally { await rm(tmp, { force: true }); }
}

export class ReleaseUpdater {
  constructor({ currentVersion, directory, config = {}, fetchImpl = fetch, npm = runNpm,
    keys, form = () => 'desktop', prepareInstall } = {}) {
    this.currentVersion = currentVersion;
    this.directory = resolve(directory);
    this.config = { source: 'github', channel: 'stable', ...config };
    this.fetch = fetchImpl; this.npm = npm; this.keys = keys; this.form = form;
    this.prepareInstall = prepareInstall;
    this.state = { phase: 'idle', currentVersion, source: this.config.source, logs: [] };
    this.candidate = null; this.busy = false;
    this.ready = this.restore();
  }

  async restore() {
    try {
      const prior = JSON.parse(await readFile(join(this.directory, 'state.json'), 'utf8'));
      if (Array.isArray(prior.logs)) this.state.logs = prior.logs.slice(-100);
      if (/^[0-9a-f]{64}$/.test(prior.stageDigest ?? '')) {
        const staged = JSON.parse(await readFile(join(this.directory, prior.stageDigest, 'release-manifest.json'), 'utf8'));
        const verified = verifyManifest(staged, { keys: this.keys });
        if (verified.digest === prior.stageDigest) {
          this.candidate = verified;
          this.state.stageDigest = prior.stageDigest;
          this.state.targetVersion = staged.version;
          this.state.phase = this.currentVersion === staged.version ? 'plugin-ready' : 'staged';
        }
      }
      if (prior.phase === 'awaiting-restart' || prior.phase === 'installing') {
        this.state = { ...this.state, phase: prior.targetVersion === this.currentVersion ? 'plugin-ready' : 'awaiting-restart',
          targetVersion: prior.targetVersion, logs: this.state.logs };
      }
    } catch { /* First start or incomplete state is not a successful update. */ }
  }

  async record(phase, code) {
    this.state = { ...this.state, phase, updatedAt: Date.now(),
      logs: [...this.state.logs, { at: Date.now(), phase, code }].slice(-100) };
    await mkdir(this.directory, { recursive: true });
    await writeJson(join(this.directory, 'state.json'), this.state);
  }

  status() {
    const app = this.candidate?.manifest.artifacts.app;
    return { ...this.state, candidate: this.candidate ? {
      version: this.candidate.manifest.version, appVersionCode: app.versionCode,
      appVersionName: app.versionName, digest: this.candidate.digest,
      available: semver.gt(this.candidate.manifest.version, this.currentVersion),
    } : null, installSupported: Boolean(this.config.profileDirectory && this.prepareInstall),
      restartMode: this.form() === 'desktop' ? 'manual' : this.config.restartCommand?.length && this.config.stopCommand?.length ? 'supervised' : 'manual' };
  }

  async refresh() {
    await this.ready;
    const digest = this.state.stageDigest;
    if (/^[0-9a-f]{64}$/.test(digest ?? '')) {
      try {
        const journal = JSON.parse(await readFile(join(this.directory, digest, 'install-journal.json'), 'utf8'));
        if (journal.phase === 'awaiting-start' && journal.version === this.currentVersion &&
            this.candidate?.manifest.version === this.currentVersion) {
          // The helper cannot observe a later manual restart. This process has
          // already restored and verified the signed pair for its own version.
          this.state.phase = 'plugin-ready';
        } else if (['rolled-back', 'recovery-required', 'awaiting-start', 'awaiting-exit', 'installing', 'failed'].includes(journal.phase)) {
          this.state.phase = journal.phase;
          if (journal.phase === 'failed') this.state.lastError = safeState({ message: journal.code });
        }
      } catch { /* No helper has run yet. */ }
    }
    return this.status();
  }

  async exclusive(action) {
    await this.ready;
    if (this.busy) throw new Error('update-in-progress');
    this.busy = true;
    try { return await action(); }
    catch (error) { await this.record('failed', safeState(error)); throw new Error(safeState(error)); }
    finally { this.busy = false; }
  }

  async json(url) {
    const response = await this.fetch(url, { signal: AbortSignal.timeout(20_000), headers: { accept: 'application/json' } });
    if (!response.ok) throw new Error(response.status === 404 ? 'release-manifest-missing' : 'update-source-unavailable');
    const text = await response.text();
    if (text.length > 256 * 1024) throw new Error('manifest-too-large');
    return JSON.parse(text);
  }

  check() { return this.exclusive(async () => {
    await this.record('checking', 'checking-selected-source');
    this.candidate = null;
    let manifest, assets;
    if (this.config.source === 'npm') {
      if (!validPackage(this.config.npmPackage)) throw new Error('official-npm-package-unconfigured');
      const tag = this.config.channel === 'stable' ? 'latest' : this.config.channel;
      const metadata = JSON.parse(await this.npm(['view', `${this.config.npmPackage}@${tag}`, '--json'], {
        cwd: this.config.profileDirectory || undefined, timeout: 30_000 }));
      manifest = metadata.dshRelease;
      if (metadata.name !== this.config.npmPackage || metadata.version !== manifest?.version ||
          manifest?.npm?.plugin !== metadata.name) throw new Error('npm-release-identity-mismatch');
    } else if (this.config.source === 'github') {
      const releases = this.config.channel === 'stable'
        ? [await this.json(`https://api.github.com/repos/${repository}/releases/latest`)]
        : await this.json(`https://api.github.com/repos/${repository}/releases?per_page=100`);
      const release = releases.filter(r => !r.draft && semver.valid(r.tag_name?.replace(/^v/, '')))
        .filter(r => this.config.channel === 'stable' ? !r.prerelease : r.tag_name.includes(`-${this.config.channel}`))
        .sort((a, b) => semver.rcompare(a.tag_name.slice(1), b.tag_name.slice(1)))[0];
      const item = release?.assets?.find(a => a.name === 'release-manifest.json');
      if (!item?.browser_download_url?.startsWith(`https://github.com/${repository}/releases/download/`)) {
        throw new Error('release-manifest-missing');
      }
      manifest = await this.json(item.browser_download_url);
      if (manifest.tag !== release.tag_name) throw new Error('release-tag-mismatch');
      assets = release.assets;
    } else { throw new Error('update-source-invalid'); }
    const verified = verifyManifest(manifest, { keys: this.keys });
    if (manifest.channel !== this.config.channel) throw new Error('release-channel-mismatch');
    if (semver.lt(manifest.version, this.currentVersion)) throw new Error('release-downgrade-refused');
    const ledgerPath = join(this.directory, 'release-ledger.json');
    let ledger = {};
    try { ledger = JSON.parse(await readFile(ledgerPath, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw new Error('release-ledger-invalid'); }
    if (ledger[manifest.version] && ledger[manifest.version] !== verified.digest) throw new Error('release-version-content-changed');
    ledger[manifest.version] = verified.digest;
    // Preserve the newest version identities across checks and process restarts.
    ledger = Object.fromEntries(Object.entries(ledger).sort(([a], [b]) => semver.rcompare(a, b)).slice(0, 100));
    await writeJson(ledgerPath, ledger);
    this.candidate = { ...verified, assets };
    await this.record('available', semver.gt(manifest.version, this.currentVersion) ? 'update-available' : 'already-current');
    return this.status();
  }); }

  stage(digest) { return this.exclusive(async () => {
    if (!this.candidate || this.candidate.digest !== digest) throw new Error('update-candidate-changed');
    const { manifest, assets } = this.candidate;
    if (!semver.gt(manifest.version, this.currentVersion)) throw new Error('release-not-newer');
    await this.record('downloading', 'downloading-paired-artifacts');
    const stage = join(this.directory, this.candidate.digest);
    const tmp = `${stage}.${randomUUID()}.staging`;
    await mkdir(tmp, { recursive: true });
    try {
      if (this.config.source === 'npm') {
        const out = JSON.parse(await this.npm(['pack', `${manifest.npm.carrier}@${manifest.version}`,
          '--ignore-scripts', '--json', '--pack-destination', tmp], { cwd: this.config.profileDirectory || undefined }));
        if (out.length !== 1 || out[0].name !== manifest.npm.carrier || out[0].version !== manifest.version ||
            !/^[\w.-]+\.tgz$/.test(out[0].filename)) throw new Error('npm-carrier-identity-mismatch');
        const names = new Set(['release-manifest.json', ...Object.values(manifest.artifacts).map(a => a.fileName)]);
        await extract({ file: join(tmp, out[0].filename), cwd: tmp, strip: 1,
          maxReadSize: 1024 * 1024, preservePaths: false, strict: true,
          filter: (path, entry) => path.startsWith('package/') && names.has(path.slice(8)) &&
            entry.type === 'File' && entry.size <= 300 * 1024 * 1024 });
        const carrier = JSON.parse(await readFile(join(tmp, 'release-manifest.json'), 'utf8'));
        if (verifyManifest(carrier, { keys: this.keys }).digest !== digest) throw new Error('npm-carrier-pair-mismatch');
      } else {
        for (const spec of Object.values(manifest.artifacts)) {
          const asset = assets.find(a => a.name === spec.fileName);
          if (!asset?.browser_download_url?.startsWith(`https://github.com/${repository}/releases/download/${manifest.tag}/`)) throw new Error('release-artifact-missing');
          await downloadArtifact(asset.browser_download_url, join(tmp, spec.fileName), spec,
            { fetchImpl: this.fetch, signal: AbortSignal.timeout(180_000) });
        }
      }
      for (const spec of Object.values(manifest.artifacts)) await verifyArtifact(join(tmp, spec.fileName), spec);
      await writeJson(join(tmp, 'release-manifest.json'), manifest);
      if (existsSync(stage)) {
        for (const spec of Object.values(manifest.artifacts)) await verifyArtifact(join(stage, spec.fileName), spec);
      } else { await rename(tmp, stage); }
      this.state.targetVersion = manifest.version;
      this.state.stageDigest = digest;
      await this.record('staged', 'paired-artifacts-verified');
      return this.status();
    } finally { await rm(tmp, { recursive: true, force: true }); }
  }); }

  install({ digest, confirmed, allowRunning = false, hasRunning = false }) { return this.exclusive(async () => {
    if (confirmed !== true) throw new Error('update-confirmation-required');
    if (hasRunning && !allowRunning) throw new Error('running-tasks-present');
    if (!this.config.profileDirectory || !this.prepareInstall) throw new Error('manual-plugin-install-required');
    if (!this.candidate || digest !== this.candidate.digest || this.state.stageDigest !== digest) throw new Error('update-not-staged');
    const manifest = this.candidate.manifest;
    const stage = join(this.directory, digest);
    for (const spec of Object.values(manifest.artifacts)) await verifyArtifact(join(stage, spec.fileName), spec);
    const profile = resolve(this.config.profileDirectory);
    if (existsSync(join(profile, 'pnpm-lock.yaml'))) throw new Error('pnpm-profile-requires-manual-update');
    await this.prepareInstall({ manifest, stage, profile, form: this.form(), config: this.config });
    this.state.targetVersion = manifest.version;
    await this.record('awaiting-restart', 'update-prepared-restart-required');
    return this.status();
  }); }

  async appArtifact() {
    await this.ready;
    const digest = this.state.stageDigest;
    if (!/^[0-9a-f]{64}$/.test(digest ?? '')) throw new Error('paired-app-not-ready');
    const stage = join(this.directory, digest);
    const manifest = JSON.parse(await readFile(join(stage, 'release-manifest.json'), 'utf8'));
    if (verifyManifest(manifest, { keys: this.keys }).digest !== digest || this.currentVersion !== manifest.version) throw new Error('plugin-version-not-active');
    const spec = manifest.artifacts.app, path = join(stage, spec.fileName);
    await verifyArtifact(path, spec);
    return { path, spec, manifest };
  }
}
