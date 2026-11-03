import { readFileSync, appendFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { validVersion } from '../lib/release-manifest.js';

/** Preparation derives a prospective tag without creating one. Publication
 * requires the existing version tag to point at the checked-out main commit. */
export function validateReleaseRequest({ version, appVersion, publish = false, requestedTag = '',
  eventName = '', eventRef = '', commit, resolveTag, isOnMain }) {
  if (!validVersion(version) || version !== appVersion) throw new Error('release-versions-disagree');
  if (!/^[0-9a-f]{40}$/.test(commit ?? '')) throw new Error('release-commit-invalid');
  const tag = `v${version}`;
  if (requestedTag && requestedTag !== tag) throw new Error('release-tag-disagrees');
  if (eventName === 'push' && eventRef !== `refs/tags/${tag}`) throw new Error('release-tag-disagrees');
  if (publish) {
    if (eventName !== 'workflow_dispatch') throw new Error('release-requires-manual-publication');
    if (!requestedTag) throw new Error('release-publication-tag-required');
    if (resolveTag(tag) !== commit) throw new Error('release-tag-commit-disagrees');
    if (!isOnMain(commit)) throw new Error('release-publication-requires-main');
  }
  return { tag, commit, publish };
}

export function main() {
  const pkg = JSON.parse(readFileSync('package.json', 'utf8'));
  const pub = readFileSync('dsh-mobile-app/pubspec.yaml', 'utf8');
  const match = /^version:\s*(\S+)\+(\d+)\s*$/m.exec(pub);
  const git = args => execFileSync('git', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  const result = validateReleaseRequest({
    version: pkg.version, appVersion: match?.[1],
    publish: process.env.RELEASE_PUBLISH === 'true', requestedTag: process.env.RELEASE_TAG ?? '',
    eventName: process.env.GITHUB_EVENT_NAME ?? 'workflow_dispatch', eventRef: process.env.GITHUB_REF ?? '',
    commit: git(['rev-parse', 'HEAD']),
    resolveTag: tag => { try { return git(['rev-parse', '--verify', `refs/tags/${tag}^{commit}`]); } catch { return null; } },
    isOnMain: commit => {
      try { git(['merge-base', '--is-ancestor', commit, 'refs/remotes/origin/main']); return true; }
      catch { return false; }
    },
  });
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `tag=${result.tag}\ncommit=${result.commit}\n`);
  console.log(`${result.publish ? 'Publication requested' : 'Preparation only'}: ${result.tag} (${result.commit})`);
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
