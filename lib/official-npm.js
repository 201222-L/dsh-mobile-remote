/** Maintainer-selected names. Registry ownership/OIDC must be established before enabling publication. */
export const officialNpm = Object.freeze({
  scope: '@201222-l',
  plugin: '@201222-l/dsh-mobile-remote',
  carrier: '@201222-l/dsh-mobile-app',
});

export function npmReleasePackages(scope) {
  if (!/^@[a-z0-9][a-z0-9._-]*$/.test(scope ?? '')) throw new Error('official-npm-scope-invalid');
  return { plugin: `${scope}/dsh-mobile-remote`, carrier: `${scope}/dsh-mobile-app` };
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
