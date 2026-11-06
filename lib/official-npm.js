/** Maintainer-selected names. Registry ownership/OIDC must be established before enabling publication. */
export const officialNpm = Object.freeze({
  scope: '@polaris-l',
  plugin: '@polaris-l/dsh-mobile-remote',
  carrier: '@polaris-l/dsh-mobile-remote-app',
});

export function npmReleasePackages(scope) {
  if (!/^@[a-z0-9][a-z0-9._-]*$/.test(scope ?? '')) throw new Error('official-npm-scope-invalid');
  return { plugin: `${scope}/dsh-mobile-remote`, carrier: `${scope}/dsh-mobile-remote-app` };
}

/** The signed release tgz keeps the legacy package name even when the profile uses a scoped install key. */
export function installedPluginNames(manifest) {
  return [...new Set(['dsh-mobile-remote', officialNpm.plugin, manifest.npm?.plugin].filter(Boolean))];
}

/** Keep the configured dependency key when installing the signed local tgz. */
export function installedPluginDependency(pkg, manifest) {
  const dependencies = { ...pkg.devDependencies, ...pkg.optionalDependencies, ...pkg.dependencies };
  const scoped = manifest.npm?.plugin ?? officialNpm.plugin;
  const legacy = Object.hasOwn(dependencies, 'dsh-mobile-remote');
  if (scoped && Object.hasOwn(dependencies, scoped)) {
    if (legacy) throw new Error('ambiguous-plugin-dependency');
    return scoped;
  }
  return 'dsh-mobile-remote';
}

/** npm may install a file tgz under the profile's dependency key without rewriting its package.json name. */
export function verifyInstalledPluginIdentity(manifest, dependency, installed) {
  const names = installedPluginNames(manifest);
  if (installed?.version !== manifest.version || !names.includes(dependency) || !names.includes(installed?.name)) {
    throw new Error('installed-plugin-version-mismatch');
  }
  return installed;
}
