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
    assert.deepEqual(caps.features, { repository: true, branches: true, graph: true, commit: true });
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

test("graph uses opaque session-bound snapshots, explicit cursors, and revalidates at most three tips", async () => {
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
    await assert.rejects(() => service.graph("session-1", repository.repositoryId, { tips: [...tips, ...tips, ...tips, ...tips] }), (e) => e.code === "graph-too-many-tips" && e.status === 400);
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

test("poll notifications contain only opaque repository ID and ignore worktree changes", async () => {
  const root = mkdtempSync(`${tmpdir()}/git-read-poll-`);
  try {
    fixture(root);
    const { writeFileSync } = await import("node:fs");
    writeFileSync(`${root}/a`, "a"); git(root, "add", "a"); git(root, "commit", "-m", "a");
    const events = [];
    const service = createGitReadService(context(root), { onChanged: (...args) => events.push(args) });
    const { repositoryId } = await service.repositoryForSession("session-1");
    writeFileSync(`${root}/a`, "uncommitted");
    await service._pollOnce();
    assert.deepEqual(events, []);
    git(root, "branch", "topic");
    await service._pollOnce();
    assert.deepEqual(events, [[repositoryId]]);
    assert.equal(JSON.stringify(events).includes(root), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("commit file pagination preserves NUL-delimited tab and newline filenames", async () => {
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
    assert.equal("email" in first, false); assert.equal("patch" in first, false); assert.deepEqual(first.refs, []); assert.deepEqual(first.tags, []);
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
