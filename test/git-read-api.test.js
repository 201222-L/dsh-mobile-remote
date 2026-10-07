import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { apply } from "../lib/index.js";

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

test("HTTP Git browser exposes read-only worktree and preview GETs and enforces auth", async () => {
  const routes = [];
  const oid = "a".repeat(40);
  const workspace = mkdtempSync(`${tmpdir()}/git-api-`);
  const session = { id: "s1", header: { cwd: workspace } };
  let graphFailure;
  const provider = {
    contractVersion: "1.0.0", capabilities: () => ({ available: true }),
    repositoryRoot: async (cwd) => cwd,
    repositoryInfo: async () => ({ headOid: oid, currentBranch: "refs/heads/main", empty: false }),
    branches: async () => [{ name: "refs/heads/main", displayName: "main", oid, kind: "local", current: true }],
    resolveTip: async () => oid,
    graph: async () => {
      if (graphFailure) throw graphFailure;
      return [{ oid, parents: [], author: "Alice", timestamp: 1, subject: "first" }];
    },
    commit: async () => ({ oid, parents: [], author: "Alice", timestamp: 1, message: "first", files: [] }),
    worktree: async () => ({ signature: "stable", entries: [{ path: "tracked.txt", status: "modified", index: true, worktree: true, conflicted: false }] }),
  };
  const services = new Map([["sessions", { get: (id) => id === session.id ? session : undefined }], ["workspaceRegistry", { list: () => [{ path: workspace }] }], ["gitReadProvider", provider]]);
  const ctx = {
    webServer: { host: "127.0.0.1", port: 43120, register(route) { routes.push(route); return () => {}; } },
    logger: { warn() {}, info() {} }, get(name) { return services.get(name); },
    provide(name, value) { services.set(name, value); }, on() { return () => {}; },
    effect(callback) { return callback?.() ?? (() => {}); }, inject() {},
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
  try {
    const caps = await request("/git/capabilities?sessionId=s1");
    assert.equal(caps.status, 200); assert.equal(caps.body.git.readOnly, true);
    const repo = await request("/git/repository?sessionId=s1");
    assert.equal(repo.status, 200);
    const query = `sessionId=s1&repositoryId=${encodeURIComponent(repo.body.repositoryId)}`;
    const branches = await request(`/git/branches?${query}`);
    assert.equal(branches.status, 200); assert.equal(branches.body.branches[0].name, "refs/heads/main");
    const graph = await request(`/git/graph?${query}`);
    assert.equal(graph.status, 200); assert.equal(graph.body.commits[0].oid, oid);
    graphFailure = Object.assign(new Error("oversized output must not leak details"), {
      code: "git-output-too-large",
      status: 413,
    });
    const oversizedGraph = await request(`/git/graph?${query}`);
    assert.equal(oversizedGraph.status, 413);
    assert.deepEqual(oversizedGraph.body, { error: "git-output-too-large" });
    graphFailure = undefined;
    const commit = await request(`/git/commit?${query}&oid=${oid}`);
    assert.equal(commit.status, 200); assert.equal(commit.body.oid, oid);
    const worktree = await request(`/git/worktree?${query}`);
    assert.equal(worktree.status, 200); assert.equal(worktree.body.repositoryId, repo.body.repositoryId); assert.equal(worktree.body.staged[0].path, "tracked.txt");
    const invalidPreview = await request(`/git/preview?${query}&kind=bogus&path=tracked.txt`);
    assert.equal(invalidPreview.status, 400);
    assert.equal((await request(`/git/worktree?${query}`, false)).status, 401);
    assert.equal((await request(`/git/preview?${query}&kind=unstaged&snapshotId=x&path=tracked.txt`, false)).status, 401);
    assert.equal((await request(`/git/write?${query}`)).status, 404);
    assert.equal((await request(`/git/branches?sessionId=missing&repositoryId=${repo.body.repositoryId}`)).status, 403);
    session.header.cwd = "/different";
    assert.equal((await request(`/git/branches?${query}`)).status, 403);
  } finally { cleanup?.(); rmSync(workspace, { recursive: true, force: true }); }
});
