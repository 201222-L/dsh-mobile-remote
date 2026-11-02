import test from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { createBundledGitReadProvider } from "../lib/git-read-bundled-provider.js";

function git(root, ...args) {
  const result = spawnSync("git", ["-C", root, ...args], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function subprocess() {
  return {
    spawn({ argv, cwd, env, signal }) {
      const childEnv = { ...process.env };
      for (const [key, value] of Object.entries(env ?? {})) {
        if (value === undefined) delete childEnv[key];
        else childEnv[key] = String(value);
      }
      const child = spawn(argv[0], argv.slice(1), { cwd, env: childEnv });
      signal?.addEventListener("abort", () => child.kill("SIGTERM"), { once: true });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (chunk) => { stdout += chunk; });
      child.stderr.on("data", (chunk) => { stderr += chunk; });
      return {
        done: new Promise((resolve) => child.on("close", (exitCode) => resolve({ exitCode }))),
        collected: {
          stdout: { readFrom: async () => ({ text: stdout, lossy: false }) },
          stderr: { readFrom: async () => ({ text: stderr, lossy: false }) },
        },
      };
    },
  };
}

function fixture(root) {
  git(root, "init", "-q", "-b", "main");
  git(root, "config", "user.name", "Alice");
  git(root, "config", "user.email", "alice@example.test");
  writeFileSync(join(root, "tracked.txt"), "tracked\n");
  git(root, "add", "tracked.txt");
  git(root, "commit", "-qm", "initial");
}

function providerFor(root) {
  return createBundledGitReadProvider({
    subprocess: subprocess(),
    get(name) {
      if (name === "workspaceRegistry") return { list: () => [{ path: root }] };
      return undefined;
    },
  });
}

test("worktree read does not execute repository-configured fsmonitor", {
  skip: process.platform === "win32" ? "POSIX sentinel script" : false,
}, async () => {
  const root = mkdtempSync(join(tmpdir(), "git-fsmonitor-"));
  try {
    fixture(root);
    const marker = join(root, "fsmonitor-executed");
    const script = join(root, "evil-fsmonitor.sh");
    writeFileSync(script, `#!/bin/sh\nprintf executed > '${marker}'\n`);
    chmodSync(script, 0o755);
    git(root, "config", "core.fsmonitor", script);

    const provider = providerFor(root);
    await provider.worktree(root);

    assert.equal(existsSync(marker), false, "Git must not execute a command from .git/config");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("worktree read does not execute repository-configured clean filters", {
  skip: process.platform === "win32" ? "POSIX sentinel script" : false,
}, async () => {
  const root = mkdtempSync(join(tmpdir(), "git-clean-filter-"));
  try {
    fixture(root);
    writeFileSync(join(root, ".gitattributes"), "tracked.txt filter=evil\n");
    git(root, "add", ".gitattributes");
    git(root, "commit", "-qm", "attributes");
    const marker = join(root, "clean-executed");
    const script = join(root, "evil-clean.sh");
    writeFileSync(script, `#!/bin/sh\nprintf executed > '${marker}'\ncat\n`);
    chmodSync(script, 0o755);
    git(root, "config", "filter.evil.clean", script);
    writeFileSync(join(root, "tracked.txt"), "changed\n");

    const result = await providerFor(root).worktree(root);

    assert.equal(existsSync(marker), false, "Git must not execute repository-configured clean filters");
    assert.ok(result.entries.some((entry) => entry.path === "tracked.txt" && entry.worktree));
    assert.match(result.signature, /^[0-9a-f]{64}$/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("worktree read does not execute repository-configured process filters", {
  skip: process.platform === "win32" ? "POSIX sentinel script" : false,
}, async () => {
  const root = mkdtempSync(join(tmpdir(), "git-process-filter-"));
  try {
    fixture(root);
    writeFileSync(join(root, ".gitattributes"), "tracked.txt filter=evil\n");
    git(root, "add", ".gitattributes");
    git(root, "commit", "-qm", "attributes");
    const marker = join(root, "process-executed");
    const script = join(root, "evil-process.sh");
    writeFileSync(script, `#!/bin/sh\nprintf executed > '${marker}'\nexit 1\n`);
    chmodSync(script, 0o755);
    git(root, "config", "filter.evil.process", script);
    writeFileSync(join(root, "tracked.txt"), "changed\n");

    const result = await providerFor(root).worktree(root);

    assert.equal(existsSync(marker), false, "Git must not execute repository-configured process filters");
    assert.ok(result.entries.some((entry) => entry.path === "tracked.txt" && entry.worktree));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("git reads clear ambient repository overrides", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-authorized-root-"));
  const outside = mkdtempSync(join(tmpdir(), "git-external-root-"));
  const previousGitDir = process.env.GIT_DIR;
  try {
    fixture(root);
    fixture(outside);
    writeFileSync(join(outside, "outside.txt"), "outside\n");
    git(outside, "add", "outside.txt");
    git(outside, "commit", "-qm", "outside-only");
    const expectedHead = git(root, "rev-parse", "HEAD");
    process.env.GIT_DIR = join(outside, ".git");

    const provider = providerFor(root);
    const repository = await provider.repositoryInfo(root);

    assert.equal(repository.headOid, expectedHead);
  } finally {
    if (previousGitDir === undefined) delete process.env.GIT_DIR;
    else process.env.GIT_DIR = previousGitDir;
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test("git reads cannot write through inherited trace and trace2 destinations", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-trace-env-"));
  const keys = ["GIT_TRACE", "GIT_TRACE_SETUP", "GIT_TRACE2", "GIT_TRACE2_EVENT", "GIT_TRACE2_PERF"];
  const previous = new Map(keys.map((key) => [key, process.env[key]]));
  try {
    fixture(root);
    const markers = keys.map((key) => join(root, `${key}-marker`));
    for (let i = 0; i < keys.length; i++) process.env[keys[i]] = markers[i];

    const provider = providerFor(root);
    const result = await provider.worktree(root);
    assert.match(result.signature, /^[0-9a-f]{64}$/);
    for (const marker of markers) assert.equal(existsSync(marker), false, `${marker} must not be created`);
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    rmSync(root, { recursive: true, force: true });
  }
});

test("git child spec disables config-controlled execution and optional index writes", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-spawn-hardening-"));
  try {
    fixture(root);
    const captured = [];
    const realExecutor = subprocess();
    const provider = createBundledGitReadProvider({
      subprocess: {
        spawn(spec) {
          captured.push(spec);
          return realExecutor.spawn(spec);
        },
      },
      get(name) {
        if (name === "workspaceRegistry") return { list: () => [{ path: root }] };
        return undefined;
      },
    });

    await provider.repositoryRoot(root);

    assert.equal(captured.length, 1);
    const spec = captured[0];
    assert.ok(spec.argv.includes("core.fsmonitor=false"));
    assert.ok(spec.argv.includes(`core.hooksPath=${process.platform === "win32" ? "NUL" : "/dev/null"}`));
    assert.ok(spec.argv.includes("--no-optional-locks"));
    assert.equal(spec.env.GIT_DIR, undefined);
    assert.equal(spec.env.GIT_WORK_TREE, undefined);
    assert.equal(spec.env.GIT_INDEX_FILE, undefined);
    assert.equal(spec.env.GIT_CONFIG_COUNT, "0");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("lossy subprocess stdout fails explicitly instead of parsing a tail slice", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-lossy-output-"));
  try {
    fixture(root);
    const provider = createBundledGitReadProvider({
      subprocess: {
        spawn() {
          return {
            done: Promise.resolve({ exitCode: 0 }),
            collected: {
              stdout: { readFrom: async () => ({ text: `${root}\n`, lossy: true }) },
              stderr: { readFrom: async () => ({ text: "", lossy: false }) },
            },
          };
        },
      },
      get(name) {
        if (name === "workspaceRegistry") return { list: () => [{ path: root }] };
        return undefined;
      },
    });

    await assert.rejects(
      () => provider.repositoryRoot(root),
      (error) => error.code === "git-output-too-large" && error.status === 413,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

function refsFixture(root) {
  fixture(root);
  writeFileSync(join(root, "second.txt"), "second\n");
  git(root, "add", "second.txt");
  git(root, "commit", "-qm", "second");
  git(root, "branch", "topic");
  git(root, "update-ref", "refs/remotes/origin/main", "HEAD");
  git(root, "update-ref", "refs/remotes/origin/HEAD", "HEAD");
  git(root, "update-ref", "refs/stash", "HEAD");
  git(root, "tag", "-a", "v1.0.0", "-m", "Release v1.0.0");
  git(root, "tag", "light");
  git(root, "tag", "-a", "nested", "-m", "Nested release", "v1.0.0");
  writeFileSync(join(root, "blob-target.txt"), "blob target\n");
  const blob = git(root, "hash-object", "-w", "blob-target.txt");
  rmSync(join(root, "blob-target.txt"));
  git(root, "tag", "-a", "blobtag", "-m", "Blob tag", blob);
  return { headOid: git(root, "rev-parse", "HEAD"), blob };
}

test("refs projects head, local, remote and tag records with annotated metadata and safe hints", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-refs-"));
  try {
    const { headOid, blob } = refsFixture(root);
    const records = await providerFor(root).refs(root);
    const byName = new Map(records.map((record) => [record.name, record]));

    assert.deepEqual(byName.get("HEAD"), { name: "HEAD", shortName: "HEAD", kind: "head", oid: headOid, commitOid: headOid, current: true, annotated: false });
    assert.equal(byName.get("refs/heads/main").current, true);
    assert.equal(byName.get("refs/heads/topic").current, false);
    assert.equal(byName.get("refs/remotes/origin/main").kind, "remoteBranch");
    assert.equal(byName.has("refs/remotes/origin/HEAD"), false, "remote symbolic HEAD is not a branch");
    assert.equal(byName.has("refs/stash"), false, "stash refs are excluded");

    const annotated = byName.get("refs/tags/v1.0.0");
    assert.equal(annotated.kind, "tag");
    assert.equal(annotated.annotated, true);
    assert.equal(annotated.commitOid, headOid);
    assert.equal(annotated.tagger, "Alice");
    assert.equal(typeof annotated.date, "number");
    assert.equal(annotated.subject, "Release v1.0.0");
    assert.equal(annotated.hint, undefined);

    const lightweight = byName.get("refs/tags/light");
    assert.equal(lightweight.annotated, false);
    assert.equal(lightweight.commitOid, headOid);
    assert.equal("tagger" in lightweight, false);

    const nested = byName.get("refs/tags/nested");
    assert.equal(nested.annotated, true);
    assert.equal(nested.commitOid, headOid);
    assert.equal(nested.hint, "nested-tag");

    const blobTag = byName.get("refs/tags/blobtag");
    assert.equal(blobTag.annotated, true);
    assert.equal(blobTag.commitOid, null);
    assert.equal(blobTag.hint, "non-commit-target");
    assert.equal(blobTag.oid === blob || /^[0-9a-f]{40,64}$/.test(blobTag.oid), true);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("file history is capped by maxCommits and reports truncation", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-history-cap-"));
  try {
    fixture(root);
    for (let index = 2; index <= 4; index++) {
      writeFileSync(join(root, "tracked.txt"), `change ${index}\n`);
      git(root, "commit", "-qam", `change ${index}`);
    }
    const provider = providerFor(root);

    const complete = await provider.fileHistory(root, "tracked.txt");
    assert.deepEqual(complete.entries.map((entry) => entry.subject), ["change 4", "change 3", "change 2", "initial"]);
    assert.deepEqual(complete.entries.map((entry) => entry.status), ["M", "M", "M", "A"]);
    assert.equal(complete.truncated, false);

    const capped = await provider.fileHistory(root, "tracked.txt", { maxCommits: 2 });
    assert.deepEqual(capped.entries.map((entry) => entry.subject), ["change 4", "change 3"]);
    assert.equal(capped.truncated, true);

    assert.deepEqual(await provider.fileHistory(root, "missing.txt"), { entries: [], truncated: false, reason: "not-tracked" });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("file history soft timeout returns the partial result with truncated: true", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-history-timeout-"));
  try {
    fixture(root);
    for (let index = 2; index <= 4; index++) {
      writeFileSync(join(root, "tracked.txt"), `change ${index}\n`);
      git(root, "commit", "-qam", `change ${index}`);
    }
    const rawLog = spawnSync("git", ["-C", root, "--literal-pathspecs", "log", "--max-count=6", "--format=%x00%H%x1f%h%x1f%an%x1f%at%x1f%s", "--name-status", "-M", "-z", "--", "tracked.txt"], { encoding: "utf8" });
    assert.equal(rawLog.status, 0, rawLog.stderr);
    const partial = rawLog.stdout.slice(0, Math.floor(rawLog.stdout.length / 2));
    const realExecutor = subprocess();
    const provider = createBundledGitReadProvider({
      subprocess: {
        spawn(spec) {
          if (!spec.argv.includes("log") || !spec.argv.includes("--name-status")) return realExecutor.spawn(spec);
          return {
            done: new Promise((resolve) => {
              spec.signal?.addEventListener("abort", () => resolve({ exitCode: null, signal: "SIGTERM" }), { once: true });
            }),
            collected: {
              stdout: { readFrom: async () => ({ text: partial, lossy: false }) },
              stderr: { readFrom: async () => ({ text: "", lossy: false }) },
            },
          };
        },
      },
      get(name) {
        if (name === "workspaceRegistry") return { list: () => [{ path: root }] };
        return undefined;
      },
    });

    const result = await provider.fileHistory(root, "tracked.txt", { timeoutMs: 20 });
    assert.equal(result.truncated, true);
    assert.ok(result.entries.length >= 1);
    for (const entry of result.entries) assert.match(entry.oid, /^[0-9a-f]{40,64}$/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("files lists HEAD-tracked paths and treats an unborn repository as empty", async () => {
  const root = mkdtempSync(join(tmpdir(), "git-files-provider-"));
  const emptyRoot = mkdtempSync(join(tmpdir(), "git-files-empty-"));
  try {
    fixture(root);
    writeFileSync(join(root, "zeta.txt"), "zeta\n");
    writeFileSync(join(root, "Alpha.txt"), "alpha\n");
    git(root, "add", ".");
    git(root, "commit", "-qm", "more");
    const provider = providerFor(root);
    assert.deepEqual(await provider.files(root, { limit: 200 }), { files: ["Alpha.txt", "tracked.txt", "zeta.txt"], truncated: false });
    assert.deepEqual(await provider.files(root, { q: "ALPHA", limit: 200 }), { files: ["Alpha.txt"], truncated: false });
    assert.deepEqual(await provider.files(root, { limit: 1 }), { files: ["Alpha.txt"], truncated: true });

    git(emptyRoot, "init", "-q", "-b", "main");
    assert.deepEqual(await providerFor(emptyRoot).files(emptyRoot, {}), { files: [], truncated: false });
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(emptyRoot, { recursive: true, force: true });
  }
});
