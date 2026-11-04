import { readFile, writeFile, copyFile, mkdir, rm } from 'node:fs/promises';
import { existsSync, openSync, closeSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawn, execFile } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runNpm } from './package-command.js';
import { verifyManifest } from './release-manifest.js';
import { verifyArtifact } from './release-updater.js';
import { installedPluginDependency } from './official-npm.js';

const wait = ms => new Promise(r => setTimeout(r, ms));
const command = argv => new Promise((resolve, reject) => {
  if (!Array.isArray(argv) || !argv.length || argv.some(s => typeof s !== 'string' || s.includes('\0'))) return reject(new Error('supervisor-command-invalid'));
  execFile(argv[0], argv.slice(1), { shell: false, windowsHide: true, timeout: 30_000 },
    error => error ? reject(new Error('supervisor-command-failed')) : resolve());
});
const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };

export async function preparePluginInstall({ manifest, stage, profile, form, config }) {
  if (!existsSync(join(profile, 'package-lock.json')) || existsSync(join(profile, 'pnpm-lock.yaml'))) {
    throw new Error('npm-lockfile-required-for-update');
  }
  // Resolve before acknowledging restart; the helper repeats this after exit.
  installedPluginDependency(JSON.parse(await readFile(join(profile, 'package.json'), 'utf8')), manifest);
  if (form !== 'desktop' && (config.stopCommand?.length || config.restartCommand?.length)) {
    if (!config.stopCommand?.length || !config.restartCommand?.length || !config.healthUrl) throw new Error('supervisor-configuration-incomplete');
    const health = new URL(config.healthUrl);
    if (!['http:', 'https:'].includes(health.protocol) || !['127.0.0.1', '[::1]', 'localhost'].includes(health.hostname) || health.username || health.password) throw new Error('health-url-invalid');
  }
  const lock = join(stage, 'install.lock');
  try { await mkdir(lock); }
  catch (error) { if (error.code === 'EEXIST') throw new Error('update-already-prepared'); throw error; }
  const request = { schemaVersion: 1, hostPid: process.pid, stage: resolve(stage), profile: resolve(profile),
    version: manifest.version, restart: form === 'desktop' ? null : {
      stop: config.stopCommand, start: config.restartCommand,
      health: config.healthUrl,
    } };
  const path = join(stage, 'install-request.json');
  let fd;
  try {
    await writeFile(path, JSON.stringify(request) + '\n', { mode: 0o600 });
    fd = openSync(join(stage, 'install-helper.log'), 'a', 0o600);
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), path], {
      detached: true, windowsHide: true, stdio: ['ignore', fd, fd], cwd: profile,
    });
    await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    child.unref();
  } catch (error) { await rm(lock, { recursive: true, force: true }); throw error; }
  finally { if (fd !== undefined) closeSync(fd); }
}

export async function applyPreparedUpdate(path, { npm = runNpm, runCommand = command, isAlive = alive,
  fetchImpl = fetch, delay = wait, keys, maxWaitMs = 30 * 60_000 } = {}) {
  const request = JSON.parse(await readFile(path, 'utf8'));
  const { stage, profile, hostPid, restart } = request;
  if (request.schemaVersion !== 1 || resolve(path) !== join(resolve(stage), 'install-request.json') ||
      !Number.isSafeInteger(hostPid) || hostPid <= 0 || hostPid === process.pid) throw new Error('install-request-invalid');
  if (!existsSync(join(profile, 'package-lock.json')) || existsSync(join(profile, 'pnpm-lock.yaml'))) throw new Error('npm-lockfile-required-for-update');
  const manifest = JSON.parse(await readFile(join(stage, 'release-manifest.json'), 'utf8'));
  verifyManifest(manifest, { keys });
  if (manifest.version !== request.version) throw new Error('install-pair-mismatch');
  for (const spec of Object.values(manifest.artifacts)) await verifyArtifact(join(stage, spec.fileName), spec);
  const profilePackage = JSON.parse(await readFile(join(profile, 'package.json'), 'utf8'));
  const dependency = installedPluginDependency(profilePackage, manifest);
  const journalPath = join(stage, 'install-journal.json');
  const record = async (phase, code) => writeFile(journalPath, JSON.stringify({ phase, code, version: manifest.version, at: Date.now() }) + '\n');
  if (existsSync(journalPath)) {
    const prior = JSON.parse(await readFile(journalPath, 'utf8'));
    if (['installing', 'rolling-back'].includes(prior.phase)) throw new Error('previous-update-recovery-required');
  }
  await delay(1000); // Let the install acknowledgement reach the initiating client.
  if (restart?.stop?.length && restart?.start?.length) {
    await record('stopping', 'stopping-web-service');
    await runCommand(restart.stop);
  }
  await record('awaiting-exit', 'waiting-for-host-exit');
  const deadline = Date.now() + maxWaitMs;
  while (isAlive(hostPid)) {
    if (Date.now() >= deadline) throw new Error('host-exit-timeout');
    await delay(1000);
  }
  const backup = join(stage, 'backup'); await mkdir(backup, { recursive: true });
  for (const name of ['package.json', 'package-lock.json']) await copyFile(join(profile, name), join(backup, name));
  await record('installing', 'installing-verified-plugin');
  try {
    // Install the signed, immutable package; no arbitrary caller-provided specs.
    await npm(['install', '--ignore-scripts', '--save-exact', '--',
      `${dependency}@file:${join(stage, manifest.artifacts.plugin.fileName)}`], { cwd: profile, timeout: 180_000 });
    const installed = JSON.parse(await readFile(join(profile, 'node_modules', dependency, 'package.json'), 'utf8'));
    if (installed.version !== manifest.version || installed.name !== 'dsh-mobile-remote') throw new Error('installed-plugin-version-mismatch');
    if (restart?.start?.length) {
      await runCommand(restart.start);
      if (restart.health) {
        const health = new URL(restart.health);
        if (!['127.0.0.1', '[::1]', 'localhost'].includes(health.hostname) || health.username || health.password) throw new Error('health-url-invalid');
        let healthy = false;
        for (let i = 0; i < 30; i++) {
          try {
            const response = await fetchImpl(health, { signal: AbortSignal.timeout(2000) });
            const value = await response.json();
            if (response.ok && value.plugin?.version === manifest.version) { healthy = true; break; }
          } catch { /* The supervisor may still be starting. */ }
          await delay(1000);
        }
        if (!healthy) throw new Error('updated-host-health-failed');
      }
      await record('plugin-ready', 'web-restarted');
    } else { await record('awaiting-start', 'plugin-installed-start-host-manually'); }
  } catch (error) {
    await record('rolling-back', 'restoring-previous-install');
    if (restart?.stop?.length) await runCommand(restart.stop).catch(() => {});
    for (const name of ['package.json', 'package-lock.json']) await copyFile(join(backup, name), join(profile, name));
    try {
      await npm(['ci', '--ignore-scripts'], { cwd: profile, timeout: 180_000 });
      if (restart?.start?.length) await runCommand(restart.start);
      await record('rolled-back', 'previous-install-restored');
    } catch { await record('recovery-required', 'automatic-rollback-failed'); }
    throw error;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  applyPreparedUpdate(process.argv[2]).catch(async error => {
    try {
      const request = JSON.parse(await readFile(process.argv[2], 'utf8'));
      const journal = join(request.stage, 'install-journal.json');
      let previous;
      try { previous = JSON.parse(await readFile(journal, 'utf8')); } catch { /* Not started. */ }
      if (!['rolled-back', 'recovery-required'].includes(previous?.phase)) {
        await writeFile(journal, JSON.stringify({ phase: 'failed',
          code: /^[a-z-]{1,80}$/.test(error?.message ?? '') ? error.message : 'update-helper-failed', at: Date.now() }));
      }
    } catch { /* Preserve the original failure without exposing local paths. */ }
    // Errors and npm output can contain paths/config credentials; keep the log stable.
    console.error('update-helper-failed: inspect install-journal.json');
    process.exitCode = 1;
  }).finally(async () => {
    try {
      const request = JSON.parse(await readFile(process.argv[2], 'utf8'));
      await rm(join(request.stage, 'install.lock'), { recursive: true, force: true });
    } catch { /* An interrupted helper leaves an explicit recovery marker. */ }
  });
}
