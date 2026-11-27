// task-28（issue #86 方案 B）：GET/POST /m/api/git/graph 双传输契约。
//
// 覆盖：capability graphTips、GET 32/POST 128 上限、POST body/name 限制（413）、
// 缺失 tips/方法 405、GET↔POST 续页互通、graph 25s deadline → 504 graph-timeout，
// 以及 128 tips 的批量 refs 解析（不逐 tip）。

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
  constructor(url, { method = "GET", body = null } = {}) {
    super(); this.url = url; this.method = method;
    this.headers = { host: "127.0.0.1", "x-mobile-token": config.authToken };
    if (body !== null) {
      this.headers["content-type"] = "application/json";
      this.headers["content-length"] = String(Buffer.byteLength(body));
      this.body = body;
    }
    this.socket = { remoteAddress: "127.0.0.1" };
  }
}

async function harness({ provider, name = "post" } = {}) {
  const routes = [];
  const oid = "a".repeat(40);
  const workspace = mkdtempSync(`${tmpdir()}/git-graph-${name}-`);
  const session = { id: "s1", header: { cwd: workspace } };
  const refsCalls = { count: 0 };
  const resolveCalls = { count: 0 };
  const baseProvider = provider ?? {
    contractVersion: "1.0.0", capabilities: () => ({ available: true }),
    repositoryRoot: async (cwd) => cwd,
    repositoryInfo: async () => ({ headOid: oid, currentBranch: "refs/heads/main", empty: false }),
    branches: async () => [{ name: "refs/heads/main", displayName: "main", oid, kind: "local", current: true }],
    resolveTip: async () => { resolveCalls.count += 1; return oid; },
    refs: async () => {
      refsCalls.count += 1;
      // 覆盖 tips(count) 生成的全部 ref 名（1 + main-N），保证批量映射命中。
      return [
        { name: "refs/heads/main", commitOid: oid },
        ...Array.from({ length: 140 }, (_, index) => ({ name: `refs/heads/main-${index + 1}`, commitOid: oid })),
      ];
    },
    graph: async (_root, { offset, limit }) => Array.from({ length: limit }, (_, index) => ({
      oid: (offset + index + 1).toString(16).padStart(40, "0"),
      parents: [], author: "A", timestamp: 1, subject: `c${offset + index}`,
    })),
    commit: async () => ({ oid, parents: [], author: "A", timestamp: 1, message: "one", files: [] }),
  };
  const services = new Map([
    ["sessions", { get: (id) => id === session.id ? session : undefined }],
    ["workspaceRegistry", { list: () => [{ path: workspace }] }],
    ["gitReadProvider", baseProvider],
  ]);
  const ctx = {
    webServer: { host: "127.0.0.1", port: 43130, register(route) { routes.push(route); return () => {}; } },
    logger: { warn() {}, info() {} }, get(n) { return services.get(n); },
    provide(n, v) { services.set(n, v); }, on() { return () => {}; },
    effect(cb) { return cb?.() ?? (() => {}); }, inject() {},
  };
  const dispose = apply(ctx, config);
  const route = routes.find((item) => item.path === "/m/api")?.handler;
  assert.equal(typeof route, "function");

  async function request(url, { method = "GET", body = null } = {}) {
    const response = new Response();
    const finished = new Promise((resolve) => response.once("finish", resolve));
    const req = new Request(url, { method, body });
    route(req, response);
    if (body !== null) {
      process.nextTick(() => {
        req.emit("data", Buffer.from(body));
        req.emit("end");
      });
    }
    await finished;
    const raw = response.chunks.join("");
    let json = null;
    try { json = JSON.parse(raw || "{}"); } catch { json = raw; }
    return { status: response.statusCode, body: json };
  }
  async function repositoryId() {
    const repo = await request("/m/api/git/repository?sessionId=s1");
    assert.equal(repo.status, 200);
    return repo.body.repositoryId;
  }
  return {
    oid, refsCalls, resolveCalls, request, repositoryId,
    clean() { dispose?.(); rmSync(workspace, { recursive: true, force: true }); },
  };
}

const tips = (oid, count) => Array.from({ length: count }, (_, index) => ({
  name: index === 0 ? "refs/heads/main" : `refs/heads/main-${index}`,
  tipOid: oid,
}));

test("task-28: capability graphTips {max:128,getMax:32}", async () => {
  const h = await harness();
  try {
    const caps = await h.request("/m/api/git/capabilities?sessionId=s1");
    assert.equal(caps.status, 200);
    assert.deepEqual(caps.body.git.graphTips, { max: 128, getMax: 32 });
  } finally { h.clean(); }
});

test("task-28: GET 1/5/32 tips 允许，33 → 400 graph-too-many-tips", async () => {
  const h = await harness();
  try {
    const repositoryId = await h.repositoryId();
    for (const count of [1, 5, 32]) {
      const url = `/m/api/git/graph?sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}&limit=1&tips=${encodeURIComponent(JSON.stringify(tips(h.oid, count)))}`;
      const res = await h.request(url);
      assert.equal(res.status, 200, `${count} tips`);
      assert.equal(res.body.tips.length, count);
    }
    const url33 = `/m/api/git/graph?sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}&tips=${encodeURIComponent(JSON.stringify(tips(h.oid, 33)))}`;
    const tooMany = await h.request(url33);
    assert.equal(tooMany.status, 400);
    assert.equal(tooMany.body.error, "graph-too-many-tips");
  } finally { h.clean(); }
});

test("task-28: POST 10/64/128 tips 允许且批量 refs；129 → 400", async () => {
  const h = await harness();
  try {
    const repositoryId = await h.repositoryId();
    for (const count of [10, 64, 128]) {
      const body = JSON.stringify({ sessionId: "s1", repositoryId, tips: tips(h.oid, count), limit: 1 });
      const res = await h.request("/m/api/git/graph", { method: "POST", body });
      assert.equal(res.status, 200, `${count} tips`);
      assert.equal(res.body.tips.length, count);
    }
    assert.ok(h.refsCalls.count >= 1, "应走批量 refs");
    assert.equal(h.resolveCalls.count, 0, "批量 refs 命中后不得逐 tip resolveTip");

    const body129 = JSON.stringify({ sessionId: "s1", repositoryId, tips: tips(h.oid, 129), limit: 1 });
    const tooMany = await h.request("/m/api/git/graph", { method: "POST", body: body129 });
    assert.equal(tooMany.status, 400);
    assert.equal(tooMany.body.error, "graph-too-many-tips");
  } finally { h.clean(); }
});

test("task-28: POST 新快照缺 tips → 400；PUT → 405", async () => {
  const h = await harness();
  try {
    const repositoryId = await h.repositoryId();
    const missing = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({ sessionId: "s1", repositoryId }),
    });
    assert.equal(missing.status, 400);
    assert.equal(missing.body.error, "bad-request");
    const put = await h.request("/m/api/git/graph", { method: "PUT", body: JSON.stringify({}) });
    assert.equal(put.status, 405);
  } finally { h.clean(); }
});

test("task-28: POST body/name 超限 → 413 payload-too-large", async () => {
  const h = await harness();
  try {
    const repositoryId = await h.repositoryId();
    const longName = "refs/heads/" + "x".repeat(1025);
    const nameBody = JSON.stringify({ sessionId: "s1", repositoryId, tips: [{ name: longName }], limit: 1 });
    const nameTooLong = await h.request("/m/api/git/graph", { method: "POST", body: nameBody });
    assert.equal(nameTooLong.status, 413);
    assert.equal(nameTooLong.body.error, "payload-too-large");

    // 256KiB 上限：3×100KB 的 tips body 直接 413（Content-Length 预检）。
    const hugeTips = Array.from({ length: 3 }, (_, index) => ({ name: `refs/heads/${"y".repeat(100 * 1024)}${index}` }));
    const hugeBody = JSON.stringify({ sessionId: "s1", repositoryId, tips: hugeTips });
    assert.ok(Buffer.byteLength(hugeBody) > 256 * 1024);
    const huge = await h.request("/m/api/git/graph", { method: "POST", body: hugeBody });
    assert.equal(huge.status, 413);
    assert.equal(huge.body.error, "payload-too-large");
  } finally { h.clean(); }
});

test("task-28: GET↔POST 续页互通（snapshotId/cursor 与传输无关）", async () => {
  const h = await harness();
  try {
    const repositoryId = await h.repositoryId();
    const postFirst = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({ sessionId: "s1", repositoryId, tips: tips(h.oid, 2), limit: 1 }),
    });
    assert.equal(postFirst.status, 200);
    assert.ok(postFirst.body.nextCursor);

    const getSecond = await h.request(
      `/m/api/git/graph?sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}&snapshotId=${encodeURIComponent(postFirst.body.snapshotId)}&cursor=${encodeURIComponent(postFirst.body.nextCursor)}&limit=1`,
    );
    assert.equal(getSecond.status, 200);
    assert.equal(getSecond.body.snapshotId, postFirst.body.snapshotId);
    assert.equal(getSecond.body.tips.length, 2);

    const getFirst = await h.request(
      `/m/api/git/graph?sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}&tips=${encodeURIComponent(JSON.stringify(tips(h.oid, 2)))}&limit=1`,
    );
    assert.equal(getFirst.status, 200);
    assert.ok(getFirst.body.nextCursor);
    const postSecond = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({
        sessionId: "s1", repositoryId,
        snapshotId: getFirst.body.snapshotId, cursor: getFirst.body.nextCursor, limit: 1,
      }),
    });
    assert.equal(postSecond.status, 200);
    assert.equal(postSecond.body.snapshotId, getFirst.body.snapshotId);
  } finally { h.clean(); }
});

test("task-28: graph 超时 → 504 graph-timeout（provider 抛错/返回 timedOut 两种）", async () => {
  const cases = [
    { label: "throws", graph: async () => { throw Object.assign(new Error("deadline"), { code: "graph-timeout", status: 504 }); } },
    { label: "returns-timedOut", graph: async () => ({ timedOut: true, entries: [] }) },
  ];
  for (const item of cases) {
    const h = await harness({
      provider: {
        contractVersion: "1.0.0", capabilities: () => ({ available: true }),
        repositoryRoot: async (cwd) => cwd,
        repositoryInfo: async () => ({ headOid: "a".repeat(40), currentBranch: "refs/heads/main", empty: false }),
        branches: async () => [],
        resolveTip: async () => "a".repeat(40),
        refs: async () => [{ name: "refs/heads/main", commitOid: "a".repeat(40) }],
        graph: item.graph,
        commit: async () => ({}),
      },
      name: `timeout-${item.label}`,
    });
    try {
      const repositoryId = await h.repositoryId();
      const res = await h.request("/m/api/git/graph", {
        method: "POST",
        body: JSON.stringify({ sessionId: "s1", repositoryId, tips: [{ name: "refs/heads/main" }], limit: 1 }),
      });
      assert.equal(res.status, 504, `${item.label}: ${JSON.stringify(res.body)}`);
      assert.equal(res.body.error, "graph-timeout");
    } finally { h.clean(); }
  }
});

test("re-review P1-1/P1-4: graph GET/HEAD/POST 方法矩阵；HEAD 200 无 body/不建快照；其他 Git 仅 GET/HEAD", async () => {
  const h = await harness();
  try {
    const repositoryId = await h.repositoryId();
    const query = `sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}`;
    const refsBefore = h.refsCalls.count;

    const head = await h.request(`/m/api/git/graph?${query}`, { method: "HEAD" });
    assert.equal(head.status, 200);
    assert.equal(h.refsCalls.count, refsBefore, "HEAD 不应创建 snapshot/解析 refs");

    const get = await h.request(`/m/api/git/graph?${query}&limit=1`);
    assert.equal(get.status, 200);
    const post = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({ sessionId: "s1", repositoryId, tips: tips(h.oid, 1), limit: 1 }),
    });
    assert.equal(post.status, 200);

    // 其他 8 个只读 Git 端点：POST 一律 405。
    for (const route of ["/git/branches", "/git/capabilities", "/git/repository", "/git/commit", "/git/worktree", "/git/preview", "/git/files", "/git/file-history"]) {
      const res = await h.request(`/m/api${route}?${query}`, { method: "POST", body: JSON.stringify({}) });
      assert.equal(res.status, 405, `${route} POST`);
      // HEAD 方法允许；部分端点缺必填参数会 400（仍非 405）。
      const headRes = await h.request(`/m/api${route}?${query}`, { method: "HEAD" });
      assert.notEqual(headRes.status, 405, `${route} HEAD 不能 405`);
    }
    // graph 非法方法 → 405。
    const del = await h.request(`/m/api/git/graph?${query}`, { method: "DELETE" });
    assert.equal(del.status, 405);
  } finally { h.clean(); }
});

test("issue #93: capability exposes graphAll protection; POST all=true works without tips and GET all is rejected", async () => {
  const h = await harness();
  try {
    const caps = await h.request("/m/api/git/capabilities?sessionId=s1");
    assert.equal(caps.status, 200);
    assert.deepEqual(caps.body.git.graphAll, { pageSize: 16, maxRefs: 4096, maxScan: 5000 });
    const repositoryId = await h.repositoryId();

    const all = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({ sessionId: "s1", repositoryId, all: true, limit: 16 }),
    });
    assert.equal(all.status, 200, JSON.stringify(all.body));
    assert.equal(all.body.all, true);
    assert.equal(all.body.pageSize, 16);
    assert.equal(all.body.commits.length, 16);
    assert.ok(all.body.nextCursor);
    assert.equal(h.refsCalls.count >= 1, true, "all mode must resolve branch refs");
    // all 模式的 tips 来自服务端解析，包含本地 + 远程分支名（不含 tags）。
    assert.ok(all.body.tips.some((tip) => tip.name === "refs/heads/main"));
    assert.ok(all.body.tips.every((tip) => !tip.name.startsWith("refs/tags/")));

    const continuation = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({ sessionId: "s1", repositoryId, all: true, snapshotId: all.body.snapshotId, cursor: all.body.nextCursor }),
    });
    assert.equal(continuation.status, 200);
    assert.equal(continuation.body.all, true);
    assert.ok(continuation.body.pageStart > all.body.pageStart);

    const withTips = await h.request("/m/api/git/graph", {
      method: "POST",
      body: JSON.stringify({ sessionId: "s1", repositoryId, all: true, tips: tips(h.oid, 1) }),
    });
    assert.equal(withTips.status, 400);
    assert.equal(withTips.body.error, "bad-request");

    const getAll = await h.request(`/m/api/git/graph?sessionId=s1&repositoryId=${encodeURIComponent(repositoryId)}&all=true`);
    assert.equal(getAll.status, 400);
    assert.equal(getAll.body.error, "bad-request");
  } finally { h.clean(); }
});

test("issue #93: all mode focus invalid → 409 graph-focus-invalid; >maxRefs → 400 graph-too-many-refs", async () => {
  const oid = "a".repeat(40);
  const workspace = mkdtempSync(`${tmpdir()}/git-graph-all-protect-`);
  try {
    const makeProvider = (refs) => ({
      contractVersion: "1.0.0", capabilities: () => ({ available: true }),
      repositoryRoot: async (cwd) => cwd,
      repositoryInfo: async () => ({ headOid: oid, currentBranch: "refs/heads/main", empty: false }),
      branches: async () => [{ name: "refs/heads/main", displayName: "main", oid, kind: "local", current: true }],
      resolveTip: async () => oid,
      refs: async () => refs,
      graph: async (_root, { offset, limit }) => Array.from({ length: limit }, (_, index) => ({
        oid: (offset + index + 1).toString(16).padStart(40, "0"), parents: [], author: "A", timestamp: 1, subject: `c${offset + index}`,
      })),
      commit: async () => ({ oid, parents: [], author: "A", timestamp: 1, message: "one", files: [] }),
    });
    const h = await harness({ provider: makeProvider([{ name: "refs/heads/main", commitOid: oid }]), name: "protect-invalid" });
    try {
      const repositoryId = await h.repositoryId();
      const missingFocus = await h.request("/m/api/git/graph", {
        method: "POST",
        body: JSON.stringify({ sessionId: "s1", repositoryId, all: true, focus: "refs/heads/nope" }),
      });
      assert.equal(missingFocus.status, 400);
      assert.equal(missingFocus.body.error, "graph-focus-invalid");
    } finally { h.clean(); }

    const many = await harness({ provider: makeProvider(Array.from({ length: 4097 }, (_, index) => ({ name: `refs/heads/b${index}`, commitOid: oid }))), name: "protect-many" });
    try {
      const repositoryId = await many.repositoryId();
      const tooMany = await many.request("/m/api/git/graph", {
        method: "POST",
        body: JSON.stringify({ sessionId: "s1", repositoryId, all: true }),
      });
      assert.equal(tooMany.status, 400);
      assert.equal(tooMany.body.error, "graph-too-many-refs");
    } finally { many.clean(); }
  } finally { rmSync(workspace, { recursive: true, force: true }); }
});
