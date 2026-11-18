import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { spawn, spawnSync } from "node:child_process";
import { createGitReadService } from "../lib/git-read-service.js";

function git(cwd, ...args) {
  const result = spawnSync("git", ["-C", cwd, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function subprocess() {
  return { spawn({ argv, cwd, env, signal }) {
    const child = spawn(argv[0], argv.slice(1), { cwd, env: { ...process.env, ...(env ?? {}) } });
    signal?.addEventListener("abort", () => child.kill("SIGTERM"), { once: true });
    let stdout = "", stderr = "";
    child.stdout.on("data", (v) => { stdout += v; }); child.stderr.on("data", (v) => { stderr += v; });
    return { done: new Promise((resolve) => child.on("close", (exitCode) => resolve({ exitCode }))), collected: {
      stdout: { readFrom: async () => ({ text: stdout }) }, stderr: { readFrom: async () => ({ text: stderr }) },
    } };
  } };
}
function fixture(root) {
  git(root, "init", "-b", "main"); git(root, "config", "user.name", "Alice"); git(root, "config", "user.email", "secret@example.com");
}
function context(root) {
  const session = { id: "session-1", header: { cwd: root } };
  return { subprocess: subprocess(), get(name) {
    if (name === "sessions") return { get: (id) => id === session.id ? session : undefined };
    if (name === "workspaceRegistry") return { list: () => [{ path: root }] };
    throw new Error(`missing ${name}`);
  } };
}

test("capabilities and repository are read-only and authorized only through a session", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-`);
  try {
    fixture(root);
    const service = createGitReadService(context(root));
    const caps = await service.capabilitiesForSession('session-1');
    assert.equal(caps.available, true);
    assert.equal(caps.readOnly, true);
    assert.deepEqual(caps.features, { repository: true, branches: true, graph: true, commit: true, worktree: true, preview: true, refsDetail: true, fileHistory: true });
    const repository = await service.repositoryForSession("session-1");
    assert.match(repository.repositoryId, /^repo_[A-Za-z0-9_-]+$/);
    assert.equal(repository.name, root.split("/").at(-1));
    assert.deepEqual({ currentBranch: repository.currentBranch, detached: repository.detached, empty: repository.empty }, { currentBranch: "refs/heads/main", detached: false, empty: true });
    assert.equal("headOid" in repository, false);
    assert.equal(JSON.stringify(repository).includes(root), false);
    await assert.rejects(() => service.repositoryForSession("missing"), (e) => e.code === "session-not-found" && e.status === 404);
    await assert.rejects(() => service.branches("missing", repository.repositoryId), (e) => e.code === "repository-not-authorized" && e.status === 403);
    await assert.rejects(() => service.branches("session-1", root), (e) => e.code === "repository-not-authorized" && e.status === 403);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("session capabilities report an unavailable repository without exposing paths", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-no-repo-`);
  try {
    const service = createGitReadService(context(root));
    assert.deepEqual(await service.capabilitiesForSession('session-1'), {
      ...service.capabilities(), available: false, reason: 'not-git-repository',
    });
    await assert.rejects(() => service.capabilitiesForSession('missing'), (e) => e.code === 'session-not-found');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("live session cwd and repository identity are checked on every bound operation", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-auth-`);
  const other = mkdtempSync(`${tmpdir()}/git-read-other-`);
  try {
    fixture(root); fixture(other);
    const active = { id: "session-1", header: { cwd: root } };
    const ctx = context(root);
    const originalGet = ctx.get;
    ctx.get = (name) => name === "sessions" ? { get: (id) => id === active.id ? active : undefined } : originalGet(name);
    const service = createGitReadService(ctx);
    const { repositoryId } = await service.repositoryForSession(active.id);
    active.header.cwd = other;
    for (const operation of [
      () => service.branches(active.id, repositoryId),
      () => service.graph(active.id, repositoryId),
      () => service.commit(active.id, repositoryId, "a".repeat(40)),
    ]) await assert.rejects(operation, (e) => e.code === "repository-not-authorized" && e.status === 403);
    active.header.cwd = root;
    active.id = "removed";
    await assert.rejects(() => service.branches("session-1", repositoryId), (e) => e.code === "session-not-found" && e.status === 404);
  } finally { rmSync(root, { recursive: true, force: true }); rmSync(other, { recursive: true, force: true }); }
});

test("read facade cannot expose provider command execution or internal authorization maps", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-surface-`);
  try {
    fixture(root);
    const service = createGitReadService(context(root));
    assert.equal(service._provider, undefined);
    assert.equal(service._bindings, undefined);
    assert.equal(service._now, undefined);
    assert.equal(service._snapshotTtlMs, undefined);
    const provider = (await import("../lib/git-read-bundled-provider.js")).createBundledGitReadProvider(context(root));
    assert.equal(provider.run, undefined);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("unavailable and incompatible external providers fall back to bundled read-only Git", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-fallback-`);
  try {
    fixture(root);
    for (const external of [
      { contractVersion: "0.0.0", capabilities: () => ({ available: true }) },
      { contractVersion: "1.0.0", capabilities: () => ({ available: false }), repositoryRoot() { throw Error("should not run"); }, branches() {}, resolveTip() {}, graph() {}, commit() {} },
    ]) {
      const ctx = context(root), get = ctx.get;
      ctx.get = (name) => name === "gitReadProvider" ? external : get(name);
      const service = createGitReadService(ctx);
      assert.equal(service.capabilities().provider, "bundled");
      assert.ok((await service.repositoryForSession("session-1")).repositoryId);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("external provider cannot authorize a repository outside canonical workspace", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-untrusted-`);
  try {
    fixture(root);
    const ctx = context(root), get = ctx.get;
    const external = {
      contractVersion: "1.0.0", capabilities: () => ({ available: true }),
      repositoryRoot: async () => "/etc", branches: async () => [], resolveTip: async () => "a".repeat(40),
      graph: async () => [], commit: async () => ({}),
    };
    ctx.get = (name) => name === "gitReadProvider" ? external : get(name);
    const service = createGitReadService(ctx);
    await assert.rejects(() => service.repositoryForSession("session-1"), (e) => e.code === "repository-not-authorized" && e.status === 403);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("compatible external provider DTOs are projected without extra path, URL, email or patch fields", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-projection-`);
  try {
    fixture(root);
    const oid = "a".repeat(40);
    const secret = { path: root, email: "secret@example.com", url: "https://private.invalid", patch: "secret patch" };
    const external = {
      contractVersion: "1.0.0", capabilities: () => ({ available: true, ...secret }),
      repositoryRoot: async () => root, repositoryInfo: async () => ({ headOid: oid, empty: false, ...secret }),
      branches: async () => [{ name: "refs/heads/main", displayName: root, tracking: secret.url, oid, ...secret }, { name: root, oid, ...secret }],
      resolveTip: async () => oid,
      graph: async () => [{ oid, parents: [], author: "Alice", timestamp: 1, subject: "subject", ...secret }],
      commit: async () => ({ oid, parents: [], author: "Alice", timestamp: 1, message: "subject", files: [{ path: "file.txt", status: "added", ...secret }], ...secret }),
    };
    const ctx = context(root), get = ctx.get;
    ctx.get = (name) => name === "gitReadProvider" ? external : get(name);
    const service = createGitReadService(ctx);
    const repo = await service.repositoryForSession("session-1");
    const results = [service.capabilities(), repo, await service.branches("session-1", repo.repositoryId), await service.graph("session-1", repo.repositoryId), await service.commit("session-1", repo.repositoryId, oid)];
    for (const result of results) {
      const json = JSON.stringify(result);
      assert.equal(json.includes(root), false);
      assert.equal(json.includes("secret@example.com"), false);
      assert.equal(json.includes("https://private.invalid"), false);
      assert.equal(json.includes("secret patch"), false);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("optional external change subscription failure falls back without breaking startup", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-subscribe-`);
  try {
    fixture(root);
    const ctx = context(root);
    const bundled = (await import("../lib/git-read-bundled-provider.js")).createBundledGitReadProvider(ctx);
    const external = { ...bundled, subscribeChanges() { throw Error("subscription unavailable"); } };
    const get = ctx.get;
    ctx.get = (name) => name === "gitReadProvider" ? external : get(name);
    const service = createGitReadService(ctx, { pollIntervalMs: 100 });
    await service.repositoryForSession("session-1");
    assert.doesNotThrow(() => service.start());
    assert.doesNotThrow(() => service.stop());
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("provider subscriptions do not require server-side worktree polling", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-subscribed-poll-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/tracked`, "base"); git(root, "add", "tracked"); git(root, "commit", "-m", "base");
    const ctx = context(root); const bundled = (await import("../lib/git-read-bundled-provider.js")).createBundledGitReadProvider(ctx);
    const external = { ...bundled, subscribeChanges: () => () => {} };
    const get = ctx.get; ctx.get = (name) => name === "gitReadProvider" ? external : get(name);
    const events = []; const service = createGitReadService(ctx, { pollIntervalMs: 10, onChanged: (...args) => events.push(args) });
    await service.repositoryForSession("session-1"); await service._pollOnce(); service.start();
    writeFileSync(`${root}/tracked`, "changed");
    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.deepEqual(events, []);
    await service.stop();
  } finally { rmSync(root, { recursive: true, force: true, maxRetries: 3 }); }
});

test("branches identify local, remote, current, upstream, ahead and behind", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-branches-`);
  try {
    fixture(root);
    await import("node:fs").then(({ writeFileSync }) => writeFileSync(`${root}/a.txt`, "one\n"));
    git(root, "add", "a.txt"); git(root, "commit", "-m", "one");
    const base = git(root, "rev-parse", "HEAD");
    git(root, "remote", "add", "origin", "https://example.invalid/repository.git");
    git(root, "update-ref", "refs/remotes/origin/main", base);
    git(root, "config", "branch.main.remote", "origin"); git(root, "config", "branch.main.merge", "refs/heads/main");
    await import("node:fs").then(({ appendFileSync }) => appendFileSync(`${root}/a.txt`, "two\n"));
    git(root, "commit", "-am", "two"); git(root, "branch", "topic");
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const value = await service.branches("session-1", repository.repositoryId);
    const main = value.branches.find((row) => row.kind === "local" && row.name === "refs/heads/main");
    assert.deepEqual(main, { name: "refs/heads/main", displayName: "main", oid: git(root, "rev-parse", "HEAD"), kind: "local", current: true, tracking: "refs/remotes/origin/main", ahead: 1, behind: 0 });
    assert.ok(value.branches.some((row) => row.kind === "remote" && row.name === "refs/remotes/origin/main" && row.displayName === "origin/main" && row.current === false));
    assert.ok(value.branches.some((row) => row.kind === "local" && row.name === "refs/heads/topic"));
    assert.equal(JSON.stringify(value).includes(root), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("graph uses opaque session-bound snapshots, explicit cursors, and revalidates at most five tips", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-graph-`);
  try {
    fixture(root);
    const { writeFileSync, appendFileSync } = await import("node:fs");
    writeFileSync(`${root}/a.txt`, "one\n"); git(root, "add", "a.txt"); git(root, "commit", "-m", "one");
    appendFileSync(`${root}/a.txt`, "two\n"); git(root, "commit", "-am", "two");
    const tipOid = git(root, "rev-parse", "refs/heads/main");
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const tips = [{ name: "refs/heads/main", tipOid }];
    const first = await service.graph("session-1", repository.repositoryId, { tips, limit: 1 });
    assert.equal(first.commits.length, 1); assert.ok(first.snapshotId); assert.ok(first.nextCursor);
    assert.doesNotMatch(first.nextCursor, /repo_|refs\/heads|^[0-9]+$/);
    await assert.rejects(() => service.graph("session-1", repository.repositoryId, { cursor: first.nextCursor }), (e) => e.code === "graph-stale" && e.status === 409);
    const second = await service.graph("session-1", repository.repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 10 });
    assert.equal(new Set([...first.commits, ...second.commits].map((row) => row.oid)).size, 2);
    const extraNames = ["topic-1", "topic-2", "topic-3", "topic-4"];
    for (const name of extraNames) git(root, "branch", name);
    const fiveTips = [
      ...tips,
      ...extraNames.map((name) => ({ name: `refs/heads/${name}`, tipOid })),
    ];
    const five = await service.graph("session-1", repository.repositoryId, { tips: fiveTips, limit: 10 });
    assert.equal(five.tips.length, 5);
    // task-28：GET 上限 32 → 33 才拒绝（POST 128 上限见 graph transport 用例）。
    const tooMany = [
      ...fiveTips,
      ...Array.from({ length: 28 }, (_, index) => ({ name: `refs/heads/extra-${index}`, tipOid })),
    ];
    assert.equal(tooMany.length, 33);
    await assert.rejects(
      () => service.graph("session-1", repository.repositoryId, { tips: tooMany }),
      (e) => e.code === "graph-too-many-tips" && e.status === 400 && /tips limit is 32/.test(e.message),
    );
    appendFileSync(`${root}/a.txt`, "three\n"); git(root, "commit", "-am", "three");
    await assert.rejects(() => service.graph("session-1", repository.repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor }), (e) => e.code === "graph-stale" && e.status === 409);
    const deletion = await service.graph("session-1", repository.repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    git(root, "branch", "-m", "main", "renamed-main");
    await assert.rejects(() => service.graph("session-1", repository.repositoryId, { snapshotId: deletion.snapshotId, cursor: deletion.nextCursor }), (e) => e.code === "graph-stale" && e.status === 409);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("graph rejects invalid OIDs and ref names before consulting Git", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-input-`);
  try {
    fixture(root);
    const service = createGitReadService(context(root));
    const { repositoryId } = await service.repositoryForSession("session-1");
    for (const tips of [[{ name: "refs/heads/main", tipOid: "not-a-hash" }], [{ name: "refs/heads/main.lock" }], [{ name: "refs/heads/x..y" }], [{ name: "HEAD~1" }]]) {
      await assert.rejects(() => service.graph("session-1", repositoryId, { tips }), (e) => e.status === 400);
    }
    await assert.rejects(() => service.commit("session-1", repositoryId, "HEAD"), (e) => e.code === "invalid-oid" && e.status === 400);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("old graph snapshots expire and cannot grow without bound", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-cache-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/a`, "a"); git(root, "add", "a"); git(root, "commit", "-m", "a");
    writeFileSync(`${root}/a`, "b"); git(root, "commit", "-am", "b");
    let clock = 1000;
    const service = createGitReadService(context(root), { now: () => clock, snapshotTtlMs: 50 });
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { limit: 1 });
    for (let index = 0; index < 140; index++) await service.graph("session-1", repositoryId, { limit: 1 });
    await assert.rejects(() => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor }), (e) => e.status === 409);
    const last = await service.graph("session-1", repositoryId, { limit: 1 });
    clock += 51;
    await assert.rejects(() => service.graph("session-1", repositoryId, { snapshotId: last.snapshotId, cursor: last.nextCursor }), (e) => e.status === 409);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("server polling detects ref changes but leaves worktree polling to the open client page", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-poll-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/a`, "a"); git(root, "add", "a"); git(root, "commit", "-m", "a");
    const events = [];
    const service = createGitReadService(context(root), { onChanged: (...args) => events.push(args) });
    const { repositoryId } = await service.repositoryForSession("session-1");
    await service._pollOnce();
    writeFileSync(`${root}/a`, "uncommitted");
    await service._pollOnce();
    assert.deepEqual(events, []);
    git(root, "branch", "topic");
    await service._pollOnce();
    assert.deepEqual(events, [[repositoryId, "refs"]]);
    assert.equal(JSON.stringify(events).includes(root), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("worktree snapshot separates staged, unstaged and untracked; previews revalidate exact members", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-worktree-`);
  try {
    fixture(root);
    const { writeFileSync, symlinkSync } = await import("node:fs");
    writeFileSync(`${root}/changed.txt`, "base\\n"); git(root, "add", "changed.txt"); git(root, "commit", "-m", "base");
    writeFileSync(`${root}/changed.txt`, "staged\\n"); git(root, "add", "changed.txt"); writeFileSync(`${root}/changed.txt`, "worktree\\n");
    writeFileSync(`${root}/untracked[magic].txt`, "new\\n");
    if (process.platform !== "win32") symlinkSync("/etc/passwd", `${root}/link`);
    const service = createGitReadService(context(root)); const { repositoryId } = await service.repositoryForSession("session-1");
    const snapshot = await service.worktree("session-1", repositoryId);
    assert.equal(snapshot.staged[0].path, "changed.txt"); assert.equal(snapshot.unstaged[0].path, "changed.txt");
    assert.ok(snapshot.untracked.some(({ path }) => path === "untracked[magic].txt"));
    const preview = await service.preview("session-1", repositoryId, { kind: "staged", snapshotId: snapshot.snapshotId, path: "changed.txt" });
    assert.match(preview.diff, /staged/); assert.equal(preview.repositoryId, repositoryId);
    if (process.platform !== "win32") {
      const safe = await service.preview("session-1", repositoryId, { kind: "untracked", snapshotId: snapshot.snapshotId, path: "link" });
      assert.match(safe.notice, /symlink/); assert.doesNotMatch(safe.diff, /root:/);
    }
    await assert.rejects(() => service.preview("session-1", repositoryId, { kind: "unstaged", snapshotId: snapshot.snapshotId, path: "../etc/passwd" }), (e) => e.status === 400);
    await assert.rejects(() => service.preview("session-1", repositoryId, { kind: "untracked", snapshotId: snapshot.snapshotId, path: ":(glob)**" }), (e) => e.status === 404);
    writeFileSync(`${root}/changed.txt`, "newer\\n");
    await assert.rejects(() => service.preview("session-1", repositoryId, { kind: "staged", snapshotId: snapshot.snapshotId, path: "changed.txt" }), (e) => e.code === "graph-stale" && e.status === 409);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("tracked previews retain context for folding; mode-only changes return an explicit notice", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-context-`);
  try {
    fixture(root);
    const { writeFileSync, chmodSync } = await import("node:fs");
    const original = Array.from({ length: 20 }, (_, index) => `line-${index}`).join("\n") + "\n";
    writeFileSync(`${root}/context.txt`, original); git(root, "add", "context.txt"); git(root, "commit", "-m", "base");
    const changed = original.replace("line-10", "changed-10"); writeFileSync(`${root}/context.txt`, changed);
    const service = createGitReadService(context(root)); const { repositoryId } = await service.repositoryForSession("session-1");
    const snapshot = await service.worktree("session-1", repositoryId);
    const preview = await service.preview("session-1", repositoryId, { kind: "unstaged", snapshotId: snapshot.snapshotId, path: "context.txt" });
    assert.match(preview.diff, /line-0/); assert.match(preview.diff, /line-19/);

    git(root, "checkout", "--", "context.txt");
    // Git index mode changes work on Windows too, without Unix chmod semantics.
    git(root, "update-index", "--chmod=+x", "context.txt");
    const modeSnapshot = await service.worktree("session-1", repositoryId);
    const modeOnly = await service.preview("session-1", repositoryId, { kind: "staged", snapshotId: modeSnapshot.snapshotId, path: "context.txt" });
    assert.match(modeOnly.notice, /mode changed/); assert.equal(modeOnly.diff, "");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("untracked preview is bounded and accurately marks large-file truncation", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-large-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/large.txt`, "x".repeat(1024 * 1024));
    const service = createGitReadService(context(root)); const { repositoryId } = await service.repositoryForSession("session-1");
    const snapshot = await service.worktree("session-1", repositoryId);
    const result = await service.preview("session-1", repositoryId, { kind: "untracked", snapshotId: snapshot.snapshotId, path: "large.txt" });
    assert.equal(Buffer.byteLength(result.diff), 512 * 1024); assert.equal(result.truncated, true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("porcelain NUL parsing preserves rename names and reports merge conflicts", { skip: process.platform === "win32" ? "POSIX-only filename characters" : false }, async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-status-`);
  try {
    fixture(root);
    const { writeFileSync, renameSync } = await import("node:fs");
    const unusual = "tab\\tand\\nline.txt";
    writeFileSync(`${root}/${unusual}`, "base\\n"); git(root, "add", "--", unusual); git(root, "commit", "-m", "base");
    renameSync(`${root}/${unusual}`, `${root}/renamed\\tfile.txt`); git(root, "add", "-A");
    const service = createGitReadService(context(root)); const { repositoryId } = await service.repositoryForSession("session-1");
    const renamed = await service.worktree("session-1", repositoryId);
    assert.ok(renamed.staged.some((file) => file.path === "renamed\\tfile.txt" && file.oldPath === unusual));
    git(root, "checkout", "-b", "side"); writeFileSync(`${root}/conflict.txt`, "side\\n"); git(root, "add", "conflict.txt"); git(root, "commit", "-m", "side");
    git(root, "checkout", "main"); writeFileSync(`${root}/conflict.txt`, "main\\n"); git(root, "add", "conflict.txt"); git(root, "commit", "-m", "main");
    const merge = spawnSync("git", ["-C", root, "merge", "side"], { encoding: "utf8" }); assert.notEqual(merge.status, 0);
    const conflicted = await service.worktree("session-1", repositoryId);
    assert.ok([...conflicted.staged, ...conflicted.unstaged].some((file) => file.path === "conflict.txt" && file.conflicted));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("commit preview supports root and merge commits against first parent", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-preview-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/root.txt`, "root body\\n"); git(root, "add", "root.txt"); git(root, "commit", "-m", "root");
    const rootOid = git(root, "rev-parse", "HEAD");
    const service = createGitReadService(context(root)); const { repositoryId } = await service.repositoryForSession("session-1");
    const rootPreview = await service.preview("session-1", repositoryId, { kind: "commit", oid: rootOid, path: "root.txt" });
    assert.match(rootPreview.diff, /root body/);
    git(root, "checkout", "-b", "side"); writeFileSync(`${root}/side.txt`, "side change\\n"); git(root, "add", "side.txt"); git(root, "commit", "-m", "side");
    git(root, "checkout", "main"); writeFileSync(`${root}/main.txt`, "main change\\n"); git(root, "add", "main.txt"); git(root, "commit", "-m", "main");
    git(root, "merge", "--no-ff", "side", "-m", "merge");
    const mergeOid = git(root, "rev-parse", "HEAD");
    const mergePreview = await service.preview("session-1", repositoryId, { kind: "commit", oid: mergeOid, path: "side.txt" });
    assert.match(mergePreview.diff, /side change/); assert.match(mergePreview.diff, /diff --git a\/side.txt b\/side.txt/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("commit file pagination preserves NUL-delimited tab and newline filenames", { skip: process.platform === "win32" ? "POSIX-only filename characters" : false }, async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-nul-`);
  try {
    fixture(root);
    const { writeFileSync, renameSync } = await import("node:fs");
    const unusual = "tab\tand\nline.txt";
    writeFileSync(`${root}/${unusual}`, "a\n");
    git(root, "add", "--", unusual); git(root, "commit", "-m", "unusual");
    const service = createGitReadService(context(root));
    const { repositoryId } = await service.repositoryForSession("session-1");
    const initial = await service.commit("session-1", repositoryId, git(root, "rev-parse", "HEAD"));
    assert.equal(initial.files.items[0].path, unusual);
    assert.equal(initial.files.items[0].additions, 1);
    renameSync(`${root}/${unusual}`, `${root}/new\tname.txt`);
    git(root, "add", "-A"); git(root, "commit", "-m", "unusual rename");
    const rename = await service.commit("session-1", repositoryId, git(root, "rev-parse", "HEAD"));
    assert.deepEqual(rename.files.items.map(({ path, oldPath, status, additions }) => ({ path, oldPath, status, additions })), [{ path: "new\tname.txt", oldPath: unusual, status: "renamed", additions: 0 }]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("commit details omit secrets and page root, rename, and binary changed files", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-commit-`);
  try {
    fixture(root);
    const { writeFileSync, renameSync } = await import("node:fs");
    writeFileSync(`${root}/a.txt`, "a\n"); writeFileSync(`${root}/b.txt`, "b\n"); writeFileSync(`${root}/image.bin`, Buffer.from([0, 1, 2, 3]));
    git(root, "add", "."); git(root, "commit", "-m", "root subject\n\nroot body");
    const rootOid = git(root, "rev-parse", "HEAD");
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const first = await service.commit("session-1", repository.repositoryId, rootOid, { filesLimit: 2 });
    assert.equal(first.parents.length, 0); assert.equal(first.author, "Alice"); assert.equal(first.message, "root subject\n\nroot body");
    assert.equal("email" in first, false); assert.equal("patch" in first, false); assert.deepEqual(first.tags, []);
    // v1.1.0 keeps the legacy decoration strings and projects them additively.
    assert.ok(first.refs.some((ref) => ref === "HEAD -> refs/heads/main"));
    assert.deepEqual(first.refsDetail.map(({ kind, shortName, oid }) => ({ kind, shortName, oid })), [{ kind: "head", shortName: "HEAD", oid: rootOid }, { kind: "localBranch", shortName: "main", oid: rootOid }]);
    assert.deepEqual(first.tagsDetail, []);
    assert.equal(first.files.items.length, 2); assert.equal(first.files.total, 3); assert.ok(first.files.nextCursor); assert.deepEqual(first.stats, { additions: 2, deletions: 0, files: 3 });
    const second = await service.commit("session-1", repository.repositoryId, rootOid, { filesCursor: first.files.nextCursor, filesLimit: 2 });
    const rootFiles = [...first.files.items, ...second.files.items];
    assert.equal(rootFiles.length, 3); assert.ok(rootFiles.some((file) => file.path === "image.bin" && file.binary === true && file.additions === null));
    renameSync(`${root}/a.txt`, `${root}/renamed.txt`); git(root, "add", "-A"); git(root, "commit", "-m", "rename");
    const renamed = await service.commit("session-1", repository.repositoryId, git(root, "rev-parse", "HEAD"), { filesLimit: 10 });
    assert.ok(renamed.files.items.some((file) => file.path === "renamed.txt" && file.oldPath === "a.txt" && file.status === "renamed"));
    await assert.rejects(() => service.commit("session-1", repository.repositoryId, rootOid, { filesCursor: first.files.nextCursor + "x" }), (e) => e.code === "invalid-files-cursor" && e.status === 400);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

function graphProvider({
	withRefs = true,
	graph = null,
	refNames = [],
	refsHangOnCall = 0,
	refsOidOnCall = 0,
	refsChangedOid = null,
	resolveHang = false,
	graphHangOnCall = 0,
	graphByCall = null,
	graphErrorOnCall = 0,
	graphError = null,
} = {}) {
	const oid = "a".repeat(40);
	const state = { refsCalls: 0, resolveCalls: 0, resolveGraphCalls: 0 };
	const provider = {
		contractVersion: "1.0.0",
		capabilities: () => ({ available: true }),
		repositoryRoot: async (cwd) => cwd,
		repositoryInfo: async () => ({ headOid: oid, currentBranch: "refs/heads/main", empty: false }),
		branches: async () => [{ name: "refs/heads/main", displayName: "main", oid, kind: "local", current: true }],
		resolveTip: async () => {
			state.resolveCalls += 1;
			if (resolveHang) return new Promise(() => {});
			return oid;
		},
		graph: async (root, options) => {
			void root;
			state.resolveGraphCalls += 1;
			if (graphError && state.resolveGraphCalls === graphErrorOnCall) throw graphError;
			if (state.resolveGraphCalls === graphHangOnCall) return new Promise(() => {});
			if (graphByCall && graphByCall[state.resolveGraphCalls - 1]) {
				return graphByCall[state.resolveGraphCalls - 1](options);
			}
			if (graph) return graph(options);
			return [{ oid, parents: [], author: "A", timestamp: 1, subject: "one" }];
		},
		commit: async () => ({ oid, parents: [], author: "A", timestamp: 1, message: "one", files: [] }),
	};
	if (withRefs) {
		provider.refs = async () => {
			state.refsCalls += 1;
			if (refsHangOnCall > 0 && state.refsCalls === refsHangOnCall) {
				return new Promise(() => {});
			}
			const refOid = refsOidOnCall > 0 && state.refsCalls === refsOidOnCall
				? (refsChangedOid ?? "b".repeat(40))
				: oid;
			return [
				{ name: "HEAD", commitOid: refOid },
				{ name: "refs/heads/main", commitOid: refOid },
				...refNames.map((name) => ({ name, commitOid: refOid })),
			];
		};
	}
	return { provider, state, oid };
}

function serviceWithProvider(provider, { graphDeadlineMs, onSnapshotDisposed } = {}) {
	const root = mkdtempSync(`${tmpdir()}/git-graph-provider-`);
	fixture(root);
	const session = { id: "session-1", header: { cwd: root } };
	const ctx = { get(name) {
		if (name === "sessions") return { get: (id) => id === session.id ? session : undefined };
		if (name === "workspaceRegistry") return { list: () => [{ path: root }] };
		if (name === "gitReadProvider") return provider;
		throw new Error(`missing ${name}`);
	} };
	return {
		root,
		service: createGitReadService(ctx, { graphDeadlineMs, onSnapshotDisposed }),
	};
}

test("task-28: 128 POST tips resolve via one provider.refs batch (no per-tip resolveTip)", async () => {
	const refNames = Array.from({ length: 128 }, (_, index) => index === 0 ? "refs/heads/main" : `refs/heads/main-${index}`);
	const { provider, state, oid } = graphProvider({ refNames });
	const { root, service } = serviceWithProvider(provider);
	try {
		const { repositoryId } = await service.repositoryForSession("session-1");
		const tips = refNames.map((name) => ({ name, tipOid: oid }));
		const page = await service.graph("session-1", repositoryId, { tips, limit: 1, maxTips: 128 });
		assert.equal(page.tips.length, 128);
		assert.equal(state.resolveGraphCalls, 1);
		// resolve(1) + pre/post verify(2) + 行 refs 装饰(1) = 4 次批量 refs；绝不逐 tip。
		assert.ok(state.refsCalls >= 2 && state.refsCalls <= 4, `refs batch calls: ${state.refsCalls}`);
		assert.equal(state.resolveCalls, 0, "批量 refs 命中后不得逐 tip resolveTip");
		// 129 → 400（POST 上限）。
		await assert.rejects(
			() => service.graph("session-1", repositoryId, { tips: [...tips, { name: "refs/heads/main-extra" }], maxTips: 128 }),
			(e) => e.code === "graph-too-many-tips" && e.status === 400 && /tips limit is 128/.test(e.message),
		);
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("task-28: 外部 provider 无 refs 时回退逐 tip（兼容旧契约）", async () => {
	const { provider, state, oid } = graphProvider({ withRefs: false });
	const { root, service } = serviceWithProvider(provider);
	try {
		const { repositoryId } = await service.repositoryForSession("session-1");
		const tips = Array.from({ length: 5 }, (_, index) => ({
			name: index === 0 ? "refs/heads/main" : `refs/heads/main-${index}`,
			tipOid: oid,
		}));
		const page = await service.graph("session-1", repositoryId, { tips, limit: 1 });
		assert.equal(page.tips.length, 5);
		assert.ok(state.resolveCalls >= 5, `fallback resolveTip calls: ${state.resolveCalls}`);
	} finally { rmSync(root, { recursive: true, force: true }); }
});

test("task-28: graph 25s 截止 → graph-timeout 504；provider timedOut 不返回半页", async () => {
	const hanging = graphProvider({ graph: () => new Promise(() => {}) });
	const first = serviceWithProvider(hanging.provider, { graphDeadlineMs: 50 });
	try {
		const { repositoryId } = await first.service.repositoryForSession("session-1");
		await assert.rejects(
			() => first.service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }] }),
			(e) => e.code === "graph-timeout" && e.status === 504,
		);
	} finally { rmSync(first.root, { recursive: true, force: true }); }

	const timedOut = graphProvider({ graph: async () => ({ timedOut: true, entries: [] }) });
	const second = serviceWithProvider(timedOut.provider);
	try {
		const { repositoryId } = await second.service.repositoryForSession("session-1");
		await assert.rejects(
			() => second.service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }] }),
			(e) => e.code === "graph-timeout" && e.status === 504,
		);
	} finally { rmSync(second.root, { recursive: true, force: true }); }
});

test("re-review P1-2: 25s absolute deadline 覆盖 refs/resolveTip/readRefRecords 各阶段", async () => {
  // refs 挂起（解析阶段）。
  const hangRefs = graphProvider({ refsHangOnCall: 1 });
  const a = serviceWithProvider(hangRefs.provider, { graphDeadlineMs: 60 });
  try {
    const { repositoryId } = await a.service.repositoryForSession("session-1");
    await assert.rejects(
      () => a.service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }] }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
  } finally { rmSync(a.root, { recursive: true, force: true }); }

  // 外部 provider 逐 tip resolveTip 挂起（解析阶段回退路径）。
  const hangResolve = graphProvider({ withRefs: false, resolveHang: true });
  const b = serviceWithProvider(hangResolve.provider, { graphDeadlineMs: 60 });
  try {
    const { repositoryId } = await b.service.repositoryForSession("session-1");
    await assert.rejects(
      () => b.service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }] }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
  } finally { rmSync(b.root, { recursive: true, force: true }); }

  // 装饰 readRefRecords 阶段挂起：refs 顺序 resolve#1 → pre#2 → post#3 → 装饰#4。
  const hangRecords = graphProvider({ refsHangOnCall: 4 });
  const c = serviceWithProvider(hangRecords.provider, { graphDeadlineMs: 80 });
  try {
    const { repositoryId } = await c.service.repositoryForSession("session-1");
    await assert.rejects(
      () => c.service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }] }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
  } finally { rmSync(c.root, { recursive: true, force: true }); }
});

test("re-review P1-3: 已交付 snapshot 的 append 超时保留，同 cursor 可重试成功", async () => {
  const oid = "a".repeat(40);
  const { provider, state } = graphProvider({
    graphHangOnCall: 2,
    graphByCall: [
      (options) => [{ oid, parents: [], author: "A", timestamp: 1, subject: "one" }].slice(0, options.limit),
      null,
      (options) => [{ oid: "b".repeat(40), parents: [], author: "A", timestamp: 2, subject: "two" }].slice(0, options.limit),
    ],
  });
  const { root, service } = serviceWithProvider(provider, { graphDeadlineMs: 80 });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    assert.ok(first.snapshotId && first.nextCursor);
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    // 同 snapshot/cursor 重试：超时未删已交付快照 → 成功续页。
    const retried = await service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 });
    assert.equal(retried.snapshotId, first.snapshotId);
    assert.equal(retried.commits[0].oid, "b".repeat(40));
    void state;
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1-3: 新建 snapshot 的初始请求超时可重试（不残留半页）", async () => {
  const oid = "a".repeat(40);
  let calls = 0;
  const provider = graphProvider();
  const base = provider.provider.graph;
  provider.provider.graph = async (root, options) => {
    calls += 1;
    if (calls === 1) return new Promise(() => {});
    return base(root, options);
  };
  const { root, service } = serviceWithProvider(provider.provider, { graphDeadlineMs: 80 });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    const retried = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    assert.ok(retried.snapshotId);
    assert.equal(retried.commits.length, 1);
    void oid;
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 分页闭环：append pre-verify 超时 → 504；同 cursor 重试 200", async () => {
  const { provider } = graphProvider({ refsHangOnCall: 5 });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 80,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    assert.ok(first.nextCursor && first.snapshotId);
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    assert.deepEqual(disposed, [], "已交付快照纯 timeout 不得清理");
    const retried = await service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 });
    assert.equal(retried.snapshotId, first.snapshotId);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 分页闭环：append post-verify 超时 → 504；同 cursor 重试 200", async () => {
  const { provider } = graphProvider({ refsHangOnCall: 6 });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 80,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    assert.deepEqual(disposed, [], "post-verify 纯 timeout 也不得清理已交付快照");
    const retried = await service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 });
    assert.equal(retried.snapshotId, first.snapshotId);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 分页闭环：装饰 readRefRecords 超时 → 504；同 cursor 重试 200", async () => {
  const { provider } = graphProvider({ refsHangOnCall: 7 });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 80,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    assert.deepEqual(disposed, []);
    const retried = await service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 });
    assert.equal(retried.snapshotId, first.snapshotId);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 分页闭环：ref 变化 → 409 stale 并清理；同 cursor 重试仍 409", async () => {
  const { provider } = graphProvider({ refsOidOnCall: 6 });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 500,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-stale" && e.status === 409,
    );
    assert.deepEqual(disposed, [first.snapshotId], "ref 变化必须清理快照");
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-stale" && e.status === 409,
    );
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 分页闭环：未交付 initial timeout 清理快照；已交付 append 保留", async () => {
  const { provider } = graphProvider({ graphHangOnCall: 1 });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 80,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    assert.equal(disposed.length, 1, "未交付 initial 超时应清理新建快照");
    // 新请求可正常重试（无残留半页）。
    const retried = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    assert.ok(retried.snapshotId);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 混合错误：provider.graph 503 → 二次 verify 挂起 → 504（不误判 stale），同 cursor 重试 200", async () => {
  const transient = Object.assign(new Error("temporary unavailable"), {
    code: "git-provider-unavailable",
    status: 503,
  });
  const { provider } = graphProvider({
    graphErrorOnCall: 2,
    graphError: transient,
    refsHangOnCall: 6,
  });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 60,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    assert.ok(first.snapshotId && first.nextCursor);
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-timeout" && e.status === 504,
    );
    assert.deepEqual(disposed, [], "混合错误下的二次 verify 超时也不得清理已交付快照");
    const retried = await service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 });
    assert.equal(retried.snapshotId, first.snapshotId);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("re-review P1 混合错误：provider.graph 503 后 verify 发现 ref 真变化 → 409 + 清理", async () => {
  const transient = Object.assign(new Error("temporary unavailable"), {
    code: "git-provider-unavailable",
    status: 503,
  });
  const { provider } = graphProvider({
    graphErrorOnCall: 2,
    graphError: transient,
    refsOidOnCall: 6,
  });
  const disposed = [];
  const { root, service } = serviceWithProvider(provider, {
    graphDeadlineMs: 500,
    onSnapshotDisposed: (id) => disposed.push(id),
  });
  try {
    const { repositoryId } = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repositoryId, { tips: [{ name: "refs/heads/main" }], limit: 1 });
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-stale" && e.status === 409,
    );
    assert.deepEqual(disposed, [first.snapshotId], "ref 真变化仍必须清理快照");
    await assert.rejects(
      () => service.graph("session-1", repositoryId, { snapshotId: first.snapshotId, cursor: first.nextCursor, limit: 1 }),
      (e) => e.code === "graph-stale" && e.status === 409,
    );
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("issue #93: all mode resolves every local/remote branch and tags stay labels only", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-all-refs-`);
  try {
    fixture(root);
    const { writeFileSync, appendFileSync } = await import("node:fs");
    writeFileSync(`${root}/a.txt`, "one\n"); git(root, "add", "a.txt"); git(root, "commit", "-m", "one");
    appendFileSync(`${root}/a.txt`, "two\n"); git(root, "commit", "-am", "two");
    const tip = git(root, "rev-parse", "HEAD");
    git(root, "branch", "topic", tip);
    git(root, "tag", "v1", tip);
    git(root, "update-ref", "refs/remotes/origin/main", tip);
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const page = await service.graph("session-1", repository.repositoryId, { all: true, limit: 1 });
    assert.equal(page.all, true);
    assert.equal(page.pageSize, 16);
    assert.equal(page.pageStart, 0);
    assert.equal(page.focusOid, null);
    const tipNames = page.tips.map((tip) => tip.name).sort();
    assert.deepEqual(tipNames, ["refs/heads/main", "refs/heads/topic", "refs/remotes/origin/main"]);
    assert.ok(!tipNames.some((name) => name.startsWith("refs/tags/")), "tags must not become tips");
    assert.equal(page.commits[0].oid, tip);
    assert.equal(page.commits.length, 2, "both commits reachable from branch tips are in page");
    assert.equal(page.commits[1].oid, git(root, "rev-parse", "HEAD~1"));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("issue #93: all mode focus locates a non-first page and supports bidirectional cursors", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-all-focus-`);
  try {
    fixture(root);
    const { writeFileSync, appendFileSync } = await import("node:fs");
    const oids = [];
    for (let index = 0; index < 40; index += 1) {
      if (index === 0) { writeFileSync(`${root}/a.txt`, `${index}\n`); git(root, "add", "a.txt"); }
      else appendFileSync(`${root}/a.txt`, `${index}\n`);
      git(root, "commit", "-am", `commit ${index}`);
      oids.push(git(root, "rev-parse", "HEAD"));
    }
    const focusOid = oids[10];
    git(root, "branch", "old", focusOid);
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repository.repositoryId, { all: true, focus: "refs/heads/old", limit: 16 });
    assert.equal(first.all, true);
    assert.equal(first.focusOid, focusOid);
    assert.ok(first.pageStart > 0, `focus page should not be first: ${first.pageStart}`);
    assert.equal(first.commits.length, 16);
    assert.ok(first.commits.some((commit) => commit.oid === focusOid), "focus commit must be in its page");
    assert.equal(first.hasNewer, true);
    assert.ok(first.prevCursor, "non-first focus page must expose prevCursor");
    assert.ok(first.nextCursor, "full page must expose nextCursor");

    const newer = await service.graph("session-1", repository.repositoryId, {
      all: true, snapshotId: first.snapshotId, cursor: first.prevCursor,
    });
    assert.ok(newer.pageStart < first.pageStart, "prev page must be newer (smaller offset)");
    assert.equal(newer.commits.length, 16);
    assert.ok(newer.nextCursor, "prev page should allow returning older");

    const older = await service.graph("session-1", repository.repositoryId, {
      all: true, snapshotId: first.snapshotId, cursor: first.nextCursor,
    });
    assert.ok(older.pageStart > first.pageStart, "next page must be older (larger offset)");
    const firstOids = new Set(first.commits.map((commit) => commit.oid));
    assert.ok(older.commits.every((commit) => !firstOids.has(commit.oid)), "pages must not overlap");
    const newerOids = new Set(newer.commits.map((commit) => commit.oid));
    assert.ok(first.commits.every((commit) => !newerOids.has(commit.oid)), "newer page must not duplicate focus page");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("issue #93: all snapshot fingerprint covers every branch; adding a branch makes continuation stale", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-all-stale-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/a.txt`, "one\n"); git(root, "add", "a.txt"); git(root, "commit", "-m", "one");
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const first = await service.graph("session-1", repository.repositoryId, { all: true, limit: 16 });
    git(root, "branch", "new-branch");
    await assert.rejects(
      () => service.graph("session-1", repository.repositoryId, { all: true, snapshotId: first.snapshotId, cursor: first.nextCursor }),
      (error) => error.code === "graph-stale" && error.status === 409,
    );
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("issue #93: all mode rejects unknown focus refs and supports 211 branches without truncation", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-all-211-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/a.txt`, "one\n"); git(root, "add", "a.txt"); git(root, "commit", "-m", "one");
    const head = git(root, "rev-parse", "HEAD");
    for (let index = 0; index < 210; index += 1) git(root, "update-ref", `refs/heads/branch-${index}`, head);
    const service = createGitReadService(context(root));
    const repository = await service.repositoryForSession("session-1");
    const page = await service.graph("session-1", repository.repositoryId, { all: true, limit: 16 });
    assert.equal(page.tips.length, 211);
    assert.equal(new Set(page.tips.map((tip) => tip.name)).size, 211);
    await assert.rejects(
      () => service.graph("session-1", repository.repositoryId, { all: true, focus: "refs/heads/does-not-exist" }),
      (error) => error.code === "graph-focus-invalid" && error.status === 400,
    );
  } finally { rmSync(root, { recursive: true, force: true }); }
});
