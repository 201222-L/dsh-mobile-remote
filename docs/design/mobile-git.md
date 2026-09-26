# Mobile Git browser

## Scope

The mobile Git browser is a read-only view over the Git repository authorized by the active session and its registered workspace. The full-screen route exposes up to three tabs in a user-selected order: branch list, selected-tip commit graph, and current worktree. Settings persists both membership and order; the first entry is the default tab. Existing branch/graph snapshot validation, cursor pagination, append-only graph layout, and one shared horizontal graph viewport remain authoritative.

No checkout, stage, unstage, commit, reset, stash, push, pull, or other repository mutation is exposed.

## Worktree observation

The Worktree tab groups porcelain status entries into staged, unstaged, and untracked lists. A file can appear in both staged and unstaged groups. Git ignore rules are honored. Conflicts remain visible with an explicit conflict status, but do not produce fabricated text previews.

The mobile page fetches a worktree snapshot on first entry to the Worktree tab, then checks for a changed snapshot about every 30 seconds while the Git route is open. A changed snapshot does not replace the displayed file list or preview. It marks the view stale and requires an explicit refresh. The service does not poll worktree state globally; its server-side poll remains limited to refs.

## File previews

Diffs are requested only when a file row is opened. Worktree previews require a currently authorized, session-bound snapshot and exact file membership; the service revalidates the snapshot before reading. Commit previews compare a commit with its first parent, or with the empty tree for a root commit. Responses are capped at 512 KiB and mark truncation explicitly.

The service classifies binary, symlink, submodule, conflict, and mode-only changes as notices rather than presenting them as ordinary text. Untracked regular-file content is bounded and displayed as additions. Text diffs include enough context for the client to collapse long unchanged runs while keeping three context lines around changed sections; users may expand those runs on demand.

## Graph presentation

The graph keeps the existing topology and paging model. Presentation uses stable, theme-aware branch colors, compact decoration labels prioritizing the current ref, curved lane transitions, and visible HEAD/merge markers. When Graph is configured first it opens the controller's deterministic default branch; if Graph is not configured, selecting a branch may open a temporary graph detail that returns to the prior tab.

## HTTP contract

- `GET /api/git/worktree?sessionId=…&repositoryId=…` returns `{repositoryId,snapshotId,staged,unstaged,untracked,truncated}`.
- `GET /api/git/preview?sessionId=…&repositoryId=…&kind=staged|unstaged|untracked&snapshotId=…&path=…` returns a bounded preview for a worktree member.
- `GET /api/git/preview?sessionId=…&repositoryId=…&kind=commit&oid=…&path=…` returns a bounded commit preview.

Both endpoints are read-only, session/workspace-authorized, and omit host paths and credentials from the response.

## Verification

Backend contract and real-temporary-repository tests live in `test/git-read-service.test.js` and `test/git-read-api.test.js`. Flutter model, controller, API, preference, settings, graph-presentation, and widget tests live under `dsh-mobile-app/test/`; run them with `flutter test` from `dsh-mobile-app` when the Flutter SDK is available.
