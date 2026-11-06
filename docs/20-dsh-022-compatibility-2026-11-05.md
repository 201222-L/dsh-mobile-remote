# DSH v0.2.2-rc.1 compatibility review

## Upstream version

Reviewed on 2026-11-05/06 against the latest DSH GitHub release, [`dsh-v0.2.2-rc.1`](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.2-rc.1), published 2026-11-04. Upstream `master` is `fcc0ad462172522aaf5c93a7b2e01f6b9f0b0159`, the release merge commit dated 2026-11-04; no later published DSH release was present during this review. Public npm tags differ from the GitHub release: `@deepseek-ai/dsh` has `next=0.2.2-rc.1`, `alpha=0.2.2-alpha.3`, and `latest=0.2.1-rc.5`.

The current unpublished `develop` plugin is `3.2.4-alpha.3` plus the commits through the compatibility review. Node 24.15.0 is available locally. DSH v0.2.2-rc.1 declares Node `>=24.9.0`; hosts running older Node must upgrade the runtime before moving to that DSH version. The plugin itself does not raise its engine floor, preserving older supported hosts.

## Compatibility findings

Four directly imported DSH peer packages (`dsh-credentials`, `dsh-llm`, `dsh-sandbox-policy`, `dsh-scope`) have a peer range `>=0.1.0-rc.6 <0.3.0`. Although the upper bound includes `0.2.2-rc.1` as a version comparison, npm's default prerelease semantics exclude it because the range did not mention the `0.2.2` prerelease base. The same issue excluded `0.2.1-rc.5` and `0.2.2-alpha.3`. Updated all four ranges with explicit prerelease branches for the released `0.2.0`, `0.2.1` and `0.2.2` series, while retaining the stable `0.1.x` / `0.2.x` range and refusing `<0.1.0-rc.6` and `0.3.0`.

An actual `npm install --dry-run --ignore-scripts --package-lock=false --legacy-peer-deps=false` against the local plugin folder and the exact four DSH `0.2.2-rc.1` peer packages plus `schemastery@3.19.0` resolved all 20 packages successfully. This did not install into the project profile or publish packages.

Verified the published `0.2.2-rc.1` package source for APIs used by this plugin:

- `dsh-session-query.readSession()` still calls `Session.create(...)`; `Session.fromRestore(...)` exists but is not used there. The `session/end-seed` marker validation also remains. This is the known legacy seeded-history limitation in issue #20; it is not represented as fixed.
- `dsh-session-query.readSurface()`, `listEvents(sessionId)`, and `readEvent({sessionId, seq, ...})` remain available for the existing explicit degraded history and configuration recovery paths.
- Agent `create(options)` / `resume(options)` and workspace registry `resolveByPath(path)` / `create(path, title)` remain available with their existing call shapes.
- Remote gateway methods retain `dispatchRpc(endpoint, payload, signal, peer)` and `openWireStream(endpoint, payload, uplink, peer, signal, control, uplinkWindow)`. The plugin's 0.2.1+ Peer adapter uses the same required argument positions.
- Cordis 4.1.0 retains `ctx.get`, `ctx.provide`, `ctx.on`, `ctx.effect`, and waterfall dispatch used by the plugin. DSH's Schemastery `~3.19.0` satisfies the plugin's `>=3.18.1` range.
- DSH v0.2.2-rc.1 publishes its packages with prerelease versions. npm's default semver rules do not treat `>=0.1.0-rc.6 <0.3.0` as admitting later 0.2.x prereleases. That previously made the four peer dependencies above fail npm resolution even though the version numbers looked in-range. Added explicit prerelease branches for 0.2.0, 0.2.1, and 0.2.2; the manifest/lock compatibility test pins supported versions and the lower/next-major boundaries.
- PR #70 only changes notification channel importance and notification-settings access. It does not change APIs consumed by the plugin. Its `MainActivity` additions occupy separate channel/lifecycle regions from the new download bridge. It was retargeted to `develop` and merged after integration checks; a follow-up regression covers the notification-permission recovery path.

No additional host API adapter change is indicated by the inspected upstream source. This is package/API-source compatibility review, not a complete boot of the DSH 0.2.2-rc.1 desktop runtime; the latest runtime includes substantial platform and package-bundle changes beyond the mobile plugin.

## Validation

- Added `test/host-compat-022.test.mjs`: checks both `package.json` and `package-lock.json` declare ranges that accept `0.1.0-rc.6`, `0.2.1-rc.5`, `0.2.2-alpha.3`, `0.2.2-rc.1` and stable `0.2.2`, while rejecting pre-lower-bound and `0.3.0` versions.
- Targeted compatibility matrix: 47/47 passed. Full Node suite: 282/282; Python: 8/8; `npm run check` passed; Flutter 3.47.0 `flutter analyze` reports no issues. These verify package resolution, metadata and the adapter seams covered by tests; they do not substitute for a complete desktop runtime boot on the new DSH release.

No release tag, GitHub Release, npm publication, desktop Harness action, phone install, or issue #20 modification was performed for this review.
