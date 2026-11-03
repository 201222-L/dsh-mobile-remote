import test from 'node:test';
import assert from 'node:assert/strict';
import { validateReleaseRequest } from '../tools/release-request.mjs';

const commit = 'a'.repeat(40);
const request = changes => ({ version: '3.2.4-alpha.1', appVersion: '3.2.4-alpha.1', commit,
  eventName: 'workflow_dispatch', resolveTag: () => commit, isOnMain: () => true, ...changes });

test('preparation works on an untagged development commit without consulting publication state', () => {
  const value = validateReleaseRequest(request({ resolveTag: () => { throw new Error('must not read'); } }));
  assert.deepEqual(value, { tag: 'v3.2.4-alpha.1', commit, publish: false });
});
test('pushing a version tag prepares artifacts without granting publication', () => {
  assert.equal(validateReleaseRequest(request({ eventName: 'push', eventRef: 'refs/tags/v3.2.4-alpha.1' })).publish, false);
});
test('pushing a tag cannot request public publication', () => {
  assert.throws(() => validateReleaseRequest(request({ publish: true, eventName: 'push',
    eventRef: 'refs/tags/v3.2.4-alpha.1', requestedTag: 'v3.2.4-alpha.1' })), /manual-publication/);
});
test('manual publication requires an explicit existing tag at the selected commit', () => {
  assert.throws(() => validateReleaseRequest(request({ publish: true })), /tag-required/);
  assert.throws(() => validateReleaseRequest(request({ publish: true, requestedTag: 'v3.2.4-alpha.1', resolveTag: () => null })), /tag-commit/);
  assert.throws(() => validateReleaseRequest(request({ publish: true, requestedTag: 'v3.2.4-alpha.1', resolveTag: () => 'b'.repeat(40) })), /tag-commit/);
});
test('publication refuses a tag outside main history', () => {
  assert.throws(() => validateReleaseRequest(request({ publish: true, requestedTag: 'v3.2.4-alpha.1', isOnMain: () => false })), /requires-main/);
});
test('an existing tag at a main commit permits manually requested publication', () => {
  assert.equal(validateReleaseRequest(request({ publish: true, requestedTag: 'v3.2.4-alpha.1' })).publish, true);
});
test('tag and App/plugin version mismatches stop before signing', () => {
  assert.throws(() => validateReleaseRequest(request({ requestedTag: 'v3.2.3' })), /tag-disagrees/);
  assert.throws(() => validateReleaseRequest(request({ appVersion: '3.2.3' })), /versions-disagree/);
  assert.throws(() => validateReleaseRequest(request({ eventName: 'push', eventRef: 'refs/tags/v3.2.3' })), /tag-disagrees/);
});
