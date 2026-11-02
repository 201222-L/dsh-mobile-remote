import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { apply } from "../lib/index.js";

// Host HTTP seam: apply() routes + the real bundled provider against temporary
// Git repositories. Assertions only cover the external measured behaviour:
// JSON response contracts, ordering, filtering, pagination and error codes.

const config = {
  path: "/m", authToken: "1234567890123456", cookieName: "dsh_mobile_token",
  trustedHosts: [], sessionTtlMs: 60_000, rechargeUrl: "https://example.test/top-up",
  maxConnections: 4, pushUrls: [], pushCooldownMs: 1, doneGraceMs: 1,
  pushContent: "minimal", rateLimit: {}, lanBridge: { enabled: false, port: 3080, host: "127.0.0.1" },
  approvalMode: "mobile",
};

class Response extends EventEmitter {
  constructor() { super(); this.chunks = []; this.headersSent = false; }
  writeHead(statusCode) { this.statusCode = statusCode; this.headersSent = true; }
  write(chunk) { this.chunks.push(String(chunk)); return true; }
  end(chunk = "") { this.chunks.push(String(chunk)); this.emit("finish"); }
  destroy() { this.emit("close"); }
}

class Request extends EventEmitter {
  constructor(url) {
    super(); this.url = url; this.method = "GET";
    this.headers = { host: "127.0.0.1", "x-mobile-token": config.authToken };
    this.socket = { remoteAddress: "127.0.0.1" };
  }
}

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

function initRepo(prefix, { initialBranch = "main" } = {}) {
  const root = mkdtempSync(join(tmpdir(), prefix));
  git(root, "init", "-q", "-b", initialBranch);
  git(root, "config", "user.name", "Alice");
  git(root, "config", "user.email", "alice@example.test");
  return root;
}

/** Repository holding branches, remotes, tags (annotated/lightweight/nested/blob) and a stash ref. */
function refFixture(prefix = "git-refs-") {
  const root = initRepo(prefix);
  mkdirSync(join(root, "docs"));
  writeFileSync(join(root, "a.txt"), "one\n");
  writeFileSync(join(root, "README.md"), "readme\n");
  writeFileSync(join(root, "docs", "guide.md"), "guide\n");
  git(root, "add", ".");
  git(root, "commit", "-qm", "initial commit");
  const firstOid = git(root, "rev-parse", "HEAD");
  writeFileSync(join(root, "a.txt"), "two\n");
  git(root, "commit", "-qam", "second commit");
  const headOid = git(root, "rev-parse", "HEAD");
  git(root, "branch", "topic");
  git(root, "branch", "feature/one", firstOid);
  git(root, "update-ref", "refs/remotes/origin/main", headOid);
  git(root, "update-ref", "refs/remotes/origin/topic", headOid);
  git(root, "update-ref", "refs/remotes/origin/HEAD", headOid);
  git(root, "update-ref", "refs/stash", headOid);
  git(root, "tag", "-a", "v1.0.0", "-m", "Release v1.0.0\n\nrelease notes");
  git(root, "tag", "light");
  git(root, "tag", "-a", "old-release", "-m", "Old release", firstOid);
  git(root, "tag", "-a", "nested", "-m", "Nested release", "v1.0.0");
  writeFileSync(join(root, "blob-content.txt"), "blob target\n");
  const targetBlob = git(root, "hash-object", "-w", "blob-content.txt");
  rmSync(join(root, "blob-content.txt"));
  git(root, "tag", "-a", "blobtag", "-m", "Blob tag", targetBlob);
  return { root, firstOid, headOid, blobOid: targetBlob };
}

function startBrowser(root, { provider } = {}) {
  const routes = [];
  const session = { id: "s1", header: { cwd: root } };
  const services = new Map([
    ["sessions", { get: (id) => id === session.id ? session : undefined }],
    ["workspaceRegistry", { list: () => [{ path: root }] }],
  ]);
  if (provider) services.set("gitReadProvider", provider);
  const ctx = {
    webServer: { host: "127.0.0.1", port: 43121, register(route) { routes.push(route); return () => {}; } },
    logger: { warn() {}, info() {} }, get(name) { return services.get(name); },
    provide(name, value) { services.set(name, value); }, on() { return () => {}; },
    effect(callback) { return callback?.() ?? (() => {}); }, inject() {},
    subprocess: provider ? undefined : subprocess(),
  };
  const cleanup = apply(ctx, config);
  const route = routes.find((item) => item.path === "/m/api")?.handler;
  assert.equal(typeof route, "function");
  async function request(path, authenticated = true) {
    const response = new Response();
    const finished = new Promise((resolve) => response.once("finish", resolve));
    const req = new Request(`/m/api${path}`);
    if (!authenticated) delete req.headers["x-mobile-token"];
    route(req, response);
    await finished;
    return { status: response.statusCode, body: JSON.parse(response.chunks.join("") || "{}") };
  }
  return { request, session, cleanup };
}

async function repositoryQuery(request) {
  const repository = await request("/git/repository?sessionId=s1");
  assert.equal(repository.status, 200);
  const { repositoryId } = repository.body;
  assert.match(repositoryId, /^repo_[A-Za-z0-9_-]+$/);
  return { repositoryId, query: `sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}` };
}

test("git capabilities advertise contract 1.1.0 and additive, independent feature flags", async () => {
  const fixture = refFixture();
  const browser = startBrowser(fixture.root);
  try {
    const capabilities = await browser.request("/git/capabilities?sessionId=s1");
    assert.equal(capabilities.status, 200);
    assert.equal(capabilities.body.git.contractVersion, "1.1.0");
    assert.equal(capabilities.body.git.readOnly, true);
    assert.equal(capabilities.body.git.provider, "bundled");
    assert.equal(capabilities.body.git.features.refsDetail, true);
    assert.equal(capabilities.body.git.features.fileHistory, true);
    assert.equal((await browser.request("/git/capabilities?sessionId=s1", false)).status, 401);
    assert.equal((await browser.request("/git/capabilities?sessionId=missing")).status, 404);
  } finally { browser.cleanup?.(); rmSync(fixture.root, { recursive: true, force: true }); }
});

test("graph rows carry legacy refs plus ordered structured refsDetail/tagsDetail and exclude stash", async () => {
  const fixture = refFixture();
  const browser = startBrowser(fixture.root);
  try {
    const { query } = await repositoryQuery(browser.request);
    const tips = encodeURIComponent(JSON.stringify([{ name: "refs/heads/main" }]));
    const graph = await browser.request(`/git/graph?${query}&tips=${tips}`);
    assert.equal(graph.status, 200);
    const head = graph.body.commits[0];
    assert.equal(head.oid, fixture.headOid);

    // Legacy decoration strings stay available (deprecated, but additive-safe).
    assert.ok(head.refs.includes("HEAD -> refs/heads/main"), "legacy refs keep raw decorations");
    assert.ok(head.refs.includes("refs/stash"), "legacy refs keep the raw stash decoration");

    assert.deepEqual(head.refsDetail.map(({ kind, shortName, oid, current }) => ({ kind, shortName, oid, ...(current === undefined ? {} : { current }) })), [
      { kind: "head", shortName: "HEAD", oid: fixture.headOid, current: true },
      { kind: "localBranch", shortName: "main", oid: fixture.headOid, current: true },
      { kind: "localBranch", shortName: "topic", oid: fixture.headOid },
      { kind: "remoteBranch", shortName: "origin/main", oid: fixture.headOid },
      { kind: "remoteBranch", shortName: "origin/topic", oid: fixture.headOid },
    ]);
    assert.equal(head.refsDetail.some((row) => row.shortName === "origin/HEAD"), false);
    assert.equal(head.refsDetail.some((row) => row.name === "refs/stash"), false);

    // Name-level graph tags: annotated flags only, no commit-detail metadata.
    assert.deepEqual(head.tagsDetail, [
      { name: "refs/tags/light", shortName: "light", oid: fixture.headOid, annotated: false },
      { name: "refs/tags/nested", shortName: "nested", oid: fixture.headOid, annotated: true },
      { name: "refs/tags/v1.0.0", shortName: "v1.0.0", oid: fixture.headOid, annotated: true },
    ]);
    assert.equal(head.tagsDetail.some((tag) => "tagger" in tag || "subject" in tag), false);
    assert.equal(head.tagsDetail.some((tag) => tag.shortName === "blobtag"), false);
  } finally { browser.cleanup?.(); rmSync(fixture.root, { recursive: true, force: true }); }
});

test("commit details expose full annotated tag metadata, bounded subjects and nested-tag hints", async () => {
  const fixture = refFixture();
  const browser = startBrowser(fixture.root);
  try {
    const { query } = await repositoryQuery(browser.request);
    const longSubject = "Long release heading ".repeat(20).slice(0, 260);
    git(fixture.root, "tag", "-a", "longtag", "-m", `${longSubject}\n\nbody should be dropped`);
    const commit = await browser.request(`/git/commit?${query}&oid=${fixture.headOid}`);
    assert.equal(commit.status, 200);
    assert.equal(commit.body.oid, fixture.headOid);
    assert.ok(commit.body.refs.some((ref) => ref.startsWith("HEAD -> refs/heads/main")));
    assert.deepEqual(commit.body.tags, []);
    assert.equal(commit.body.refsDetail[0].kind, "head");
    assert.equal(commit.body.refsDetail.some((row) => row.name === "refs/stash"), false);

    const byTag = new Map(commit.body.tagsDetail.map((tag) => [tag.shortName, tag]));
    assert.deepEqual([...byTag.keys()], ["light", "longtag", "nested", "v1.0.0"]);
    assert.equal(byTag.get("light").annotated, false);
    assert.equal("tagger" in byTag.get("light"), false);
    assert.equal(byTag.get("v1.0.0").annotated, true);
    assert.equal(byTag.get("v1.0.0").tagger, "Alice");
    assert.equal(typeof byTag.get("v1.0.0").date, "number");
    assert.ok(byTag.get("v1.0.0").date > 0);
    assert.equal(byTag.get("v1.0.0").subject, "Release v1.0.0");
    assert.equal(byTag.get("nested").annotated, true);
    assert.equal(byTag.get("nested").hint, "nested-tag");
    assert.equal([...byTag.get("longtag").subject].length, 200);
    assert.equal([...byTag.get("longtag").subject].join(""), longSubject.slice(0, 200));
    assert.equal(byTag.has("blobtag"), false);
    for (const tag of commit.body.tagsDetail) assert.equal(tag.oid, fixture.headOid);

    const older = await browser.request(`/git/commit?${query}&oid=${fixture.firstOid}`);
    assert.equal(older.status, 200);
    assert.deepEqual(older.body.tagsDetail.map((tag) => [tag.shortName, tag.annotated]), [["old-release", true]]);
    assert.equal((await browser.request(`/git/commit?${query}&oid=${"a".repeat(40)}`, true)).status, 400);
  } finally { browser.cleanup?.(); rmSync(fixture.root, { recursive: true, force: true }); }
});

test("tracked file listing filters case-insensitively, sorts by path and bounds limit", async () => {
  const root = initRepo("git-files-");
  const browser = startBrowser(root);
  try {
    mkdirSync(join(root, "docs"));
    mkdirSync(join(root, "src"));
    writeFileSync(join(root, "README.md"), "readme\n");
    writeFileSync(join(root, "a.txt"), "a\n");
    writeFileSync(join(root, "docs", "guide.md"), "guide\n");
    writeFileSync(join(root, "src", "App.js"), "app\n");
    git(root, "add", ".");
    git(root, "commit", "-qm", "files");
    writeFileSync(join(root, "untracked.txt"), "untracked\n");
    rmSync(join(root, "a.txt"));
    const { query } = await repositoryQuery(browser.request);

    const all = await browser.request(`/git/files?${query}`);
    assert.equal(all.status, 200);
    assert.deepEqual(all.body.files, ["README.md", "a.txt", "docs/guide.md", "src/App.js"]);
    assert.equal(all.body.truncated, false);

    assert.deepEqual((await browser.request(`/git/files?${query}&q=read`)).body.files, ["README.md"]);
    assert.deepEqual((await browser.request(`/git/files?${query}&q=APP`)).body.files, ["src/App.js"]);
    assert.deepEqual((await browser.request(`/git/files?${query}&q=.md`)).body.files, ["README.md", "docs/guide.md"]);
    assert.deepEqual((await browser.request(`/git/files?${query}&q=untracked`)).body.files, []);

    const limited = await browser.request(`/git/files?${query}&limit=2`);
    assert.deepEqual(limited.body.files, ["README.md", "a.txt"]);
    assert.equal(limited.body.truncated, true);
    assert.equal((await browser.request(`/git/files?${query}&limit=999`)).body.files.length, 4);
    assert.equal((await browser.request(`/git/files?${query}`, false)).status, 401);
    assert.equal((await browser.request(`/git/files?sessionId=s1&repositoryId=repo_missing`)).status, 403);
  } finally { browser.cleanup?.(); rmSync(root, { recursive: true, force: true }); }
});

test("file history paginates with an opaque cursor, normalizes paths and reports empty reasons", async () => {
  const root = initRepo("git-history-");
  const browser = startBrowser(root);
  try {
    mkdirSync(join(root, "docs"));
    writeFileSync(join(root, "docs", "a.txt"), "v1\n");
    git(root, "add", ".");
    git(root, "commit", "-qm", "add a");
    const addOid = git(root, "rev-parse", "HEAD");
    const commits = [];
    for (let index = 2; index <= 5; index++) {
      writeFileSync(join(root, "docs", "a.txt"), `v${index}\n`);
      git(root, "commit", "-qam", `change ${index}`);
      commits.push(git(root, "rev-parse", "HEAD"));
    }
    const newestFirst = [...commits].reverse().concat(addOid);
    writeFileSync(join(root, "untracked.txt"), "untracked\n");
    const { repositoryId, query } = await repositoryQuery(browser.request);
    const path = encodeURIComponent("docs/a.txt");

    // Literal path handling: bracket/space names are not interpreted as pathspecs.
    const trickyPath = "docs/odd [1].md";
    writeFileSync(join(root, trickyPath), "one\n");
    git(root, "add", "--", trickyPath);
    git(root, "commit", "-qm", "odd name");
    const tricky = await browser.request(`/git/file-history?${query}&path=${encodeURIComponent(trickyPath)}`);
    assert.equal(tricky.status, 200);
    assert.deepEqual(tricky.body.entries.map((entry) => [entry.subject, entry.status]), [["odd name", "A"]]);

    const first = await browser.request(`/git/file-history?${query}&path=${path}&limit=2`);
    assert.equal(first.status, 200);
    assert.equal(first.body.path, "docs/a.txt");
    assert.deepEqual(first.body.entries.map((entry) => entry.oid), newestFirst.slice(0, 2));
    assert.deepEqual(first.body.entries.map((entry) => entry.subject), ["change 5", "change 4"]);
    assert.deepEqual(first.body.entries.map((entry) => entry.status), ["M", "M"]);
    assert.match(first.body.entries[0].shortOid, /^[0-9a-f]{4,40}$/);
    assert.equal(typeof first.body.entries[0].timestamp, "number");
    assert.equal(first.body.truncated, false);
    assert.ok(first.body.nextCursor);
    assert.equal(JSON.stringify(first.body).includes(root), false);

    const second = await browser.request(`/git/file-history?${query}&path=${path}&limit=2&cursor=${encodeURIComponent(first.body.nextCursor)}`);
    assert.equal(second.status, 200);
    assert.deepEqual(second.body.entries.map((entry) => entry.oid), newestFirst.slice(2, 4));
    const third = await browser.request(`/git/file-history?${query}&path=${path}&limit=2&cursor=${encodeURIComponent(second.body.nextCursor)}`);
    assert.deepEqual(third.body.entries.map((entry) => entry.oid), newestFirst.slice(4));
    assert.equal(third.body.nextCursor, null);

    // An opaque cursor is bound to this repository + path.
    assert.equal((await browser.request(`/git/file-history?${query}&path=README.md&cursor=${encodeURIComponent(first.body.nextCursor)}`)).status, 400);
    const badCursor = await browser.request(`/git/file-history?${query}&path=${path}&cursor=bogus`);
    assert.equal(badCursor.status, 400);
    assert.equal(badCursor.body.error, "invalid-history-cursor");

    // Workspace-absolute and repository-relative paths address the same file.
    const absolute = await browser.request(`/git/file-history?${query}&path=${encodeURIComponent(join(root, "docs", "a.txt"))}&limit=1`);
    assert.equal(absolute.status, 200);
    assert.deepEqual(absolute.body.entries.map((entry) => entry.oid), newestFirst.slice(0, 1));

    const traversal = await browser.request(`/git/file-history?${query}&path=${encodeURIComponent("../outside.txt")}`);
    assert.equal(traversal.status, 200);
    assert.deepEqual(traversal.body, { ok: true, repositoryId, path: "../outside.txt", entries: [], nextCursor: null, truncated: false, reason: "path-invalid" });
    const outside = await browser.request(`/git/file-history?${query}&path=${encodeURIComponent("/etc/passwd")}`);
    assert.equal(outside.status, 200);
    assert.equal(outside.body.reason, "path-invalid");

    const directory = await browser.request(`/git/file-history?${query}&path=docs`);
    assert.equal(directory.status, 400);
    assert.equal(directory.body.error, "path-invalid");
    const repoRoot = await browser.request(`/git/file-history?${query}&path=${encodeURIComponent(root)}`);
    assert.equal(repoRoot.status, 400);

    const untracked = await browser.request(`/git/file-history?${query}&path=untracked.txt`);
    assert.equal(untracked.status, 200);
    assert.deepEqual(untracked.body, { ok: true, repositoryId: untracked.body.repositoryId, path: "untracked.txt", entries: [], nextCursor: null, truncated: false, reason: "not-tracked" });

    assert.equal((await browser.request(`/git/file-history?${query}`)).status, 400);
    assert.equal((await browser.request(`/git/file-history?${query}&path=${path}`, false)).status, 401);
  } finally { browser.cleanup?.(); rmSync(root, { recursive: true, force: true }); }
});

test("empty repositories answer file listing and history with explicit empty results", async () => {
  const root = initRepo("git-empty-");
  const browser = startBrowser(root);
  try {
    const repository = await browser.request("/git/repository?sessionId=s1");
    assert.equal(repository.status, 200);
    assert.equal(repository.body.empty, true);
    const query = `sessionId=s1&repositoryId=${encodeURIComponent(repository.body.repositoryId)}`;
    const files = await browser.request(`/git/files?${query}`);
    assert.equal(files.status, 200);
    assert.deepEqual(files.body.files, []);
    const history = await browser.request(`/git/file-history?${query}&path=a.txt`);
    assert.equal(history.status, 200);
    assert.deepEqual(history.body, { ok: true, repositoryId: repository.body.repositoryId, path: "a.txt", entries: [], nextCursor: null, truncated: false, reason: "no-history" });
  } finally { browser.cleanup?.(); rmSync(root, { recursive: true, force: true }); }
});

test("legacy 1.0.0 external providers stay compatible, synthesize structured refs and never inherit bundled file APIs", async () => {
  const root = initRepo("git-legacy-");
  try {
    const oid = "a".repeat(40);
    const session = { id: "s1", header: { cwd: root } };
    const provider = {
      contractVersion: "1.0.0",
      capabilities: () => ({ available: true }),
      repositoryRoot: async () => root,
      repositoryInfo: async () => ({ headOid: oid, currentBranch: "refs/heads/main", empty: false }),
      branches: async () => [{ name: "refs/heads/main", oid, current: true }],
      resolveTip: async () => oid,
      graph: async () => [{ oid, parents: [], author: "Legacy", timestamp: 1, subject: "legacy", refs: ["HEAD -> refs/heads/main", "refs/heads/topic", "refs/remotes/origin/main", "refs/remotes/origin/HEAD", "refs/stash", "tag: refs/tags/v1.0.0"] }],
      commit: async () => ({ oid, parents: [], author: "Legacy", timestamp: 1, message: "legacy", refs: ["HEAD -> main", "tag: short-tag", "refs/stash"], tags: ["legacy-tag"], files: [] }),
    };
    const routes = [];
    const services = new Map([
      ["sessions", { get: (id) => id === session.id ? session : undefined }],
      ["workspaceRegistry", { list: () => [{ path: root }] }],
      ["gitReadProvider", provider],
    ]);
    const ctx = {
      webServer: { host: "127.0.0.1", port: 43122, register(route) { routes.push(route); return () => {}; } },
      logger: { warn() {}, info() {} }, get(name) { return services.get(name); },
      provide(name, value) { services.set(name, value); }, on() { return () => {}; },
      effect(callback) { return callback?.() ?? (() => {}); }, inject() {},
      // The bundled provider IS available here; the active provider is still the
      // legacy external one, so file-history must not be advertised or mixed in.
      subprocess: subprocess(),
    };
    const cleanup = apply(ctx, config);
    const route = routes.find((item) => item.path === "/m/api")?.handler;
    async function request(path) {
      const response = new Response();
      const finished = new Promise((resolve) => response.once("finish", resolve));
      route(new Request(`/m/api${path}`), response);
      await finished;
      return { status: response.statusCode, body: JSON.parse(response.chunks.join("") || "{}") };
    }
    try {
      const capabilities = await request("/git/capabilities?sessionId=s1");
      assert.equal(capabilities.status, 200);
      assert.equal(capabilities.body.git.contractVersion, "1.1.0");
      assert.equal(capabilities.body.git.provider, "external");
      assert.equal(capabilities.body.git.features.refsDetail, true);
      // Bundled Git is usable, but the ACTIVE provider lacks the new methods:
      // the capability must stay false rather than mixing providers.
      assert.equal(capabilities.body.git.features.fileHistory, false);

      const repository = await request("/git/repository?sessionId=s1");
      const query = `sessionId=s1&repositoryId=${encodeURIComponent(repository.body.repositoryId)}`;
      const graph = await request(`/git/graph?${query}&tips=${encodeURIComponent(JSON.stringify([{ name: "refs/heads/main" }]))}`);
      assert.equal(graph.status, 200);
      const row = graph.body.commits[0];
      assert.deepEqual(row.refs, ["HEAD -> refs/heads/main", "refs/heads/topic", "refs/remotes/origin/main", "refs/remotes/origin/HEAD", "refs/stash", "tag: refs/tags/v1.0.0"]);
      assert.deepEqual(row.refsDetail.map(({ kind, shortName, current }) => ({ kind, shortName, ...(current === undefined ? {} : { current }) })), [
        { kind: "head", shortName: "HEAD", current: true },
        { kind: "localBranch", shortName: "main", current: true },
        { kind: "localBranch", shortName: "topic" },
        { kind: "remoteBranch", shortName: "origin/main" },
      ]);
      assert.deepEqual(row.tagsDetail, [{ name: "refs/tags/v1.0.0", shortName: "v1.0.0", oid, annotated: false }]);

      const commit = await request(`/git/commit?${query}&oid=${oid}`);
      assert.equal(commit.status, 200);
      assert.deepEqual(commit.body.refsDetail.map(({ kind, shortName, current }) => ({ kind, shortName, ...(current === undefined ? {} : { current }) })), [
        { kind: "head", shortName: "HEAD", current: true },
        { kind: "localBranch", shortName: "main", current: true },
      ]);
      assert.deepEqual(commit.body.tagsDetail.map(({ name, shortName, oid: tagOid, annotated }) => ({ name, shortName, oid: tagOid, annotated })), [
        { name: "refs/tags/legacy-tag", shortName: "legacy-tag", oid, annotated: false },
        { name: "refs/tags/short-tag", shortName: "short-tag", oid, annotated: false },
      ]);

      // Fail closed with a stable code; never serve bundled data behind the
      // external provider's graph/commit facts.
      const files = await request(`/git/files?${query}`);
      assert.equal(files.status, 503);
      assert.deepEqual(files.body, { error: "provider-incompatible" });
      const history = await request(`/git/file-history?${query}&path=a.txt`);
      assert.equal(history.status, 503);
      assert.deepEqual(history.body, { error: "provider-incompatible" });
    } finally { cleanup?.(); }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("1.1.0 external providers supply files/file-history and both are projected without leaking raw fields", async () => {
  const root = initRepo("git-provider-v11-");
  try {
    const oid = "b".repeat(40);
    const session = { id: "s1", header: { cwd: root } };
    const provider = {
      contractVersion: "1.1.0",
      capabilities: () => ({ available: true }),
      repositoryRoot: async () => root,
      repositoryInfo: async () => ({ headOid: oid, currentBranch: "refs/heads/main", empty: false }),
      branches: async () => [],
      resolveTip: async () => oid,
      graph: async () => [{ oid, parents: [], author: "Provider", timestamp: 1, subject: "synthetic", refs: [] }],
      commit: async () => ({ oid, parents: [], author: "Provider", timestamp: 1, message: "synthetic", refs: [], files: [] }),
      refs: async () => [
        { name: "HEAD", shortName: "HEAD", kind: "head", oid, commitOid: oid, current: true, annotated: false },
        { name: "refs/tags/v2.0.0", shortName: "v2.0.0", kind: "tag", oid: "c".repeat(40), commitOid: oid, annotated: true, tagger: "Release Bot", date: 1_700_000_000, subject: "Synthetic release" },
      ],
      files: async (_root, { q, limit }) => ({
        files: (q === "b" ? ["zeta.md", "Beta.txt"] : ["zeta.md", "Beta.txt"]).slice(0, limit),
        truncated: true,
      }),
      fileHistory: async () => ({ entries: [
        { oid: "1".repeat(40), shortOid: "1111111", author: "Alice", timestamp: 3, subject: "newest", status: "modified", patch: "secret patch" },
        { oid: "2".repeat(40), shortOid: "2222222", author: "Alice", timestamp: 2, subject: "middle", status: "added" },
        { oid: "3".repeat(40), shortOid: "3333333", author: "Alice", timestamp: 1, subject: "oldest", status: "deleted" },
      ], truncated: true }),
    };
    const routes = [];
    const services = new Map([
      ["sessions", { get: (id) => id === session.id ? session : undefined }],
      ["workspaceRegistry", { list: () => [{ path: root }] }],
      ["gitReadProvider", provider],
    ]);
    const ctx = {
      webServer: { host: "127.0.0.1", port: 43123, register(route) { routes.push(route); return () => {}; } },
      logger: { warn() {}, info() {} }, get(name) { return services.get(name); },
      provide(name, value) { services.set(name, value); }, on() { return () => {}; },
      effect(callback) { return callback?.() ?? (() => {}); }, inject() {},
    };
    const cleanup = apply(ctx, config);
    const route = routes.find((item) => item.path === "/m/api")?.handler;
    async function request(path) {
      const response = new Response();
      const finished = new Promise((resolve) => response.once("finish", resolve));
      route(new Request(`/m/api${path}`), response);
      await finished;
      return { status: response.statusCode, body: JSON.parse(response.chunks.join("") || "{}") };
    }
    try {
      const capabilities = await request("/git/capabilities?sessionId=s1");
      assert.equal(capabilities.body.git.features.refsDetail, true);
      assert.equal(capabilities.body.git.features.fileHistory, true);
      const repository = await request("/git/repository?sessionId=s1");
      const query = `sessionId=s1&repositoryId=${encodeURIComponent(repository.body.repositoryId)}`;

      const commit = await request(`/git/commit?${query}&oid=${oid}`);
      assert.deepEqual(commit.body.tagsDetail, [{ name: "refs/tags/v2.0.0", shortName: "v2.0.0", oid, annotated: true, tagger: "Release Bot", date: 1_700_000_000, subject: "Synthetic release" }]);

      const files = await request(`/git/files?${query}&q=b&limit=2`);
      assert.equal(files.status, 200);
      assert.deepEqual(files.body.files, ["Beta.txt", "zeta.md"]);
      assert.equal(files.body.truncated, true);

      const history = await request(`/git/file-history?${query}&path=a.txt&limit=2`);
      assert.equal(history.status, 200);
      assert.deepEqual(history.body.entries.map(({ oid: entryOid, shortOid, status }) => ({ oid: entryOid, shortOid, status })), [
        { oid: "1".repeat(40), shortOid: "1111111", status: "M" },
        { oid: "2".repeat(40), shortOid: "2222222", status: "A" },
      ]);
      assert.equal(history.body.truncated, true);
      assert.ok(history.body.nextCursor);
      assert.equal(JSON.stringify(history.body).includes("secret patch"), false);
    } finally { cleanup?.(); }
  } finally { rmSync(root, { recursive: true, force: true }); }
});
