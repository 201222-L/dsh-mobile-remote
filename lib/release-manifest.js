import { createHash, createPublicKey, sign, verify, createPrivateKey } from 'node:crypto';

// Retain the maintainer's existing release public key from the archived updater.
// Private signing material stays in the maintainer's local/CI secret storage.
export const trustedReleaseKeys = {
  'dsh-release-2026': '8mxoxGDHb4gaiLM1Lz-sIknhrdoN0tHadKXQmKIcCVc',
};

export const canonicalJson = value => {
  if (value === null || typeof value !== 'object') {
    if (typeof value === 'number' && !Number.isFinite(value)) throw new Error('manifest-invalid');
    const text = JSON.stringify(value);
    if (text === undefined) throw new Error('manifest-invalid');
    return text;
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
};
export const unsignedManifest = manifest => {
  const { signatures, ...payload } = manifest;
  return payload;
};
export const manifestDigest = manifest => createHash('sha256')
  .update(canonicalJson(unsignedManifest(manifest))).digest('hex');

export function signManifest(payload, { keyId, seed }) {
  if (!/^[A-Za-z0-9_-]{1,80}$/.test(keyId ?? '') || Buffer.from(seed ?? '', 'base64url').length !== 32) {
    throw new Error('release-signing-key-invalid');
  }
  const key = createPrivateKey({ key: Buffer.concat([
    Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(seed, 'base64url'),
  ]), format: 'der', type: 'pkcs8' });
  return { ...payload, signatures: [{ keyId,
    signature: sign(null, Buffer.from(canonicalJson(payload)), key).toString('base64url'),
  }] };
}

const safeFile = name => typeof name === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/.test(name);
export const validPackage = name => typeof name === 'string' && /^@[a-z0-9][a-z0-9._-]*\/[a-z0-9][a-z0-9._-]*$/.test(name);
export const validVersion = version => typeof version === 'string' && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/.test(version);

export function verifyManifest(manifest, { repository = '201222-L/dsh-mobile-remote', keys = trustedReleaseKeys } = {}) {
  if (!manifest || manifest.schemaVersion !== 1 || manifest.repository !== repository ||
      !validVersion(manifest.version) || manifest.tag !== `v${manifest.version}` ||
      !['stable', 'alpha', 'rc'].includes(manifest.channel) ||
      !/^[0-9a-f]{40}$/.test(manifest.commit ?? '')) throw new Error('manifest-invalid');
  for (const kind of ['plugin', 'app']) {
    const a = manifest.artifacts?.[kind];
    if (!a || !safeFile(a.fileName) || !/^[0-9a-f]{64}$/.test(a.sha256 ?? '') ||
        !Number.isSafeInteger(a.size) || a.size <= 0 || a.size > (kind === 'app' ? 300 : 30) * 1024 * 1024) {
      throw new Error('manifest-artifact-invalid');
    }
  }
  if (!manifest.artifacts.plugin.fileName.endsWith('.tgz') || !manifest.artifacts.app.fileName.endsWith('.apk')) {
    throw new Error('manifest-artifact-invalid');
  }
  if (manifest.artifacts.app.versionName !== manifest.version ||
      !Number.isSafeInteger(manifest.artifacts.app.versionCode) || manifest.artifacts.app.versionCode <= 0 ||
      manifest.artifacts.app.packageName !== 'com.dsh.remote' ||
      !/^[0-9a-f]{64}$/.test(manifest.artifacts.app.certificateSha256 ?? '')) throw new Error('manifest-app-invalid');
  if (manifest.npm && (!validPackage(manifest.npm.plugin) || !validPackage(manifest.npm.carrier) ||
      manifest.npm.plugin === manifest.npm.carrier)) throw new Error('manifest-package-invalid');
  const bytes = Buffer.from(canonicalJson(unsignedManifest(manifest)));
  const verified = (manifest.signatures ?? []).some(item => {
    const raw = keys[item.keyId];
    if (!raw || Buffer.from(raw, 'base64url').length !== 32) return false;
    try {
      const key = createPublicKey({ key: Buffer.concat([
        Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(raw, 'base64url'),
      ]), type: 'spki', format: 'der' });
      return verify(null, bytes, key, Buffer.from(item.signature, 'base64url'));
    } catch { return false; }
  });
  if (!verified) throw new Error('manifest-signature-invalid');
  return { manifest, digest: manifestDigest(manifest) };
}
