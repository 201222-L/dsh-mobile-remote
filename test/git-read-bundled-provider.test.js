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
