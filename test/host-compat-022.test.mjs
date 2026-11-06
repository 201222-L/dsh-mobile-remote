import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import semver from 'semver';

const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const peerLock = JSON.parse(await readFile(new URL('../package-lock.json', import.meta.url), 'utf8'))
  .packages[''].peerDependencies;
const hostedRc = '0.2.2-rc.1';
const supportedReleases = ['0.1.0-rc.6', '0.2.0-rc.1', '0.2.1-rc.5', '0.2.2-alpha.3', hostedRc, '0.2.2'];

test('declared DSH peer range and lock agree with latest 0.2.2-rc.1 prerelease dependencies', () => {
  for (const name of [
    '@deepseek-ai/dsh-credentials',
    '@deepseek-ai/dsh-llm',
    '@deepseek-ai/dsh-sandbox-policy',
    '@deepseek-ai/dsh-scope',
  ]) {
    const range = manifest.peerDependencies[name];
    assert.equal(range, peerLock[name], `${name} package.json and package-lock.json differ`);
    for (const version of supportedReleases) {
      assert.equal(semver.satisfies(version, range), true, `${name}@${version} must be installable`);
    }
    assert.equal(semver.satisfies('0.1.0-rc.5', range), false, `${name} must keep its lower bound`);
    assert.equal(semver.satisfies('0.1.0-rc.10', range), true, `${name} should accept later 0.1.0 release candidates`);
    assert.equal(semver.satisfies('0.3.0-rc.1', range), false, `${name} must keep the next-major boundary`);
  }
  assert.equal(semver.satisfies('3.19.0', manifest.peerDependencies['@deepseek-ai/schemastery']), true);
});
