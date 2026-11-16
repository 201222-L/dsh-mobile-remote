/**
 * issue #87：DSH 0.2.2-rc.2 两处宿主契约破坏（ADR 0017 能力漂移）。
 *
 * rc.1: listChildren(parent, signal) + interruptByParent(child,parent,mode)
 * rc.2: listDescendants(root, signal) 递归 + interruptByUser(childSessionId)
 * 本文件用两代真实形状夹具，断言插件按**能力探测**分叉，而不是版本号。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply, firstAgent } from "../lib/index.js";

const CONFIG = {
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
    this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken };
    if (body !== null) {
      this.headers["content-type"] = "application/json";
      this.headers["content-length"] = String(Buffer.byteLength(body));
      this.body = body;
    }
    this.socket = { remoteAddress: "127.0.0.1" };
  }
}

const PARENT = "session-parent";
const agent = { id: PARENT, session: { id: PARENT, header: { cwd: "/tmp/proj" } }, status: "idle" };

function harness({ generation = "rc2", descendants = null, descendantsThrows = false, children = null, sessions = [], receipt = generation === "rc2" ? { accepted: true } : undefined, emptySubagents = false, omitSubagents = false, agentsRegistry = null, rpcValue = null } = {}) {
  const routes = [];
  const rpcCalls = [];
  const provided = new Map();
  const sessionList = [
    { id: PARENT, header: { id: PARENT, cwd: "/tmp/proj", createdAt: 1000 } },
    ...sessions,
  ];
  provided.set("agents", agentsRegistry ?? { get: (id) => (id === PARENT ? agent : undefined), list: () => [agent], roots: () => [] });
  provided.set("sessions", { get: (id) => sessionList.find((s) => s.id === id), list: () => sessionList });
  const subagents = {};
  if (!emptySubagents && !omitSubagents && generation === "rc2") {
    subagents.listDescendants = async (root, signal) => {
      if (descendantsThrows) throw new Error("descendants unavailable");
      return descendants ?? [];
    };
    subagents.interruptByUser = async () => ({ accepted: true });
  } else if (!emptySubagents && !omitSubagents) {
    subagents.interruptByParent = async () => undefined;
  }
  if (!emptySubagents && !omitSubagents && children !== null) subagents.listChildren = async (parent, signal) => children;
  if (!omitSubagents) provided.set("subagents", subagents);
  const gateway = {
    async invokeRpc(endpoint, payload, signal, peer) {
      rpcCalls.push({ endpoint, args: payload?.args ?? payload });
      return { ok: true, value: rpcValue ?? receipt };
    },
    async openWireStream(endpoint, payload, uplink, peer, signal, control) {
      throw new Error("unused");
    },
  };
  provided.set("typertGateway", gateway);
  provided.set("connection", { createPeer: () => ({ signal: new AbortController().signal, dispose() {} }) });
  provided.set("jobs", { list: () => [], kill: () => "requested", events: { subscribe: () => () => {} } });
  provided.set("settings", { get: () => undefined, describe: () => [] });
  provided.set("permissionPresets", { names: [], presets: {}, apply() {} });
  provided.set("workspaceRegistry", { list: () => [], enqueueOperation: async (fn) => fn(), requireState: () => ({}), setState: async () => undefined });
  provided.set("llm", { listProviders: () => [], listConfigurableProviders: () => [], listModels: async () => [] });
  provided.set("approval", { setPolicy() {}, current: () => "mobile" });
  provided.set("credentials", { describe: () => [], resolve: () => undefined });
  provided.set("commands", { list: () => [] });
  provided.set("userQuestions", { list: () => [] });
  provided.set("messageFeedback", { list: () => [] });
  const ctx = {
    webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
    logger: { warn() {}, info() {} },
    get(name) { return provided.get(name); }, provide(name, value) { provided.set(name, value); },
    on() { return () => {}; }, effect(cb) { return cb?.() ?? (() => {}); }, inject() {},
    async waterfall() { return "unavailable"; },
  };
  const dispose = apply(ctx, CONFIG);
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
  return { request, rpcCalls, dispose() { dispose?.(); } };
}

test("issue #87 rc.2：interruptByUser + 单字段 payload + accepted receipt", async () => {
  const h = harness({ generation: "rc2", descendants: [] });
  try {
    const res = await h.request("/m/api/subagents/interrupt", {
      method: "POST",
      body: JSON.stringify({ parentSessionId: PARENT, childSessionId: "child-1" }),
    });
    assert.equal(res.status, 200, JSON.stringify(res.body));
    assert.deepEqual(res.body, { ok: true, accepted: true });
    assert.deepEqual(h.rpcCalls.at(-1), {
      endpoint: "subagents/interruptByUser",
      args: { childSessionId: "child-1" },
    });
  } finally { h.dispose(); }
});

test("issue #87 rc.2：listDescendants depth1 过滤 + diagnostic 三枚举 + createdAt 回落/沉底", async () => {
  const h = harness({
    generation: "rc2",
    descendants: [
      { id: "child-live", depth: 1, kind: "child", mode: "continuable", label: "live label", activity: "running" },
      { id: "child-missing-time", depth: 1, kind: "child", mode: "continuable", label: "no time" },
      { id: "grandchild", depth: 2, kind: "child", mode: "continuable", label: "grand" },
      { id: "diag-unsupported", depth: 1, kind: "diagnostic", reason: "unsupported", label: "diag unsupported" },
      { id: "diag-corrupt", depth: 1, kind: "diagnostic", reason: "corrupt" },
      { id: "diag-unavailable", depth: 1, kind: "diagnostic", reason: "unavailable" },
    ],
    sessions: [
      { id: "child-live", header: { id: "child-live", createdAt: 3000 } },
      { id: "diag-unsupported", header: { id: "diag-unsupported", createdAt: 2000 } },
    ],
  });
  try {
    const res = await h.request(`/m/api/subagents?parentSessionId=${PARENT}`);
    assert.equal(res.status, 200);
    assert.equal(res.body.catalogDegraded, undefined, "rc.2 目录成功不得标 degraded");
    const byId = new Map(res.body.subagents.map((row) => [row.id, row]));
    assert.equal(byId.has("grandchild"), false, "只取 depth===1");
    assert.equal(byId.get("child-live").createdAt, 3000, "无 createdAt 时回落 session.header.createdAt");
    // session.header.createdAt 实际未填到 descendant 行：插件映射仍应回落。
    // （child-missing-time 不在 sessions 注册表 → 沉底）
    const ids = res.body.subagents.map((row) => row.id);
    // createdAt 缺失项整体沉底（组内 id 升序），不抢占有时间项的位置。
    assert.ok(ids.indexOf("child-missing-time") > ids.indexOf("diag-unsupported"));
    assert.deepEqual(ids.slice(2), ["child-missing-time", "diag-corrupt", "diag-unavailable"]);
    assert.equal(ids.filter((id) => id === "child-missing-time").length, 1);
    assert.equal(byId.get("diag-unsupported").kind, "diagnostic");
    assert.equal(byId.get("diag-unsupported").status, "unsupported");
    assert.equal(byId.get("diag-corrupt").status, "corrupt");
    assert.equal(byId.get("diag-unavailable").status, "unavailable");
    assert.equal("mode" in byId.get("diag-unsupported"), false);
  } finally { h.dispose(); }
});

test("issue #87 rc.1：interruptByParent 三字段 + listChildren diagnostic/createdAt 不回归", async () => {
  const h = harness({
    generation: "rc1",
    children: [
      { id: "child-a", createdAt: 2000, mode: "continuable", label: "A" },
      { id: "child-b", createdAt: 1000, mode: "unknown" },
    ],
    sessions: [{ id: "child-a", header: { id: "child-a", createdAt: 1500 } }],
  });
  try {
    const list = await h.request(`/m/api/subagents?parentSessionId=${PARENT}`);
    assert.equal(list.status, 200);
    const ids = list.body.subagents.map((row) => row.id);
    assert.deepEqual(ids, ["child-a", "child-b"]);
    assert.equal(list.body.subagents[1].kind, "diagnostic");
    assert.equal(list.body.subagents[1].status, "unsupported");
    const interrupt = await h.request("/m/api/subagents/interrupt", {
      method: "POST",
      body: JSON.stringify({ parentSessionId: PARENT, childSessionId: "child-a" }),
    });
    assert.equal(interrupt.status, 200, JSON.stringify(interrupt.body));
    assert.deepEqual(interrupt.body, { ok: true });
    assert.deepEqual(h.rpcCalls.at(-1), {
      endpoint: "subagents/interruptByParent",
      args: { childSessionId: "child-a", parentSessionId: PARENT, mode: "continuable" },
    });
  } finally { h.dispose(); }
});

test("issue #87：rc.2 listDescendants 失败时回退 listChildren（不标 degraded）", async () => {
  const h = harness({
    generation: "rc2",
    descendantsThrows: true,
    children: [{ id: "child-legacy", createdAt: 2000, mode: "continuable", label: "legacy" }],
    sessions: [{ id: "child-legacy", header: { id: "child-legacy", createdAt: 1500 } }],
  });
  try {
    const res = await h.request(`/m/api/subagents?parentSessionId=${PARENT}`);
    assert.equal(res.status, 200);
    assert.equal(res.body.catalogDegraded, undefined);
    assert.deepEqual(res.body.subagents.map((row) => row.id), ["child-legacy"]);
    assert.equal(res.body.subagents[0].createdAt, 2000);
  } finally { h.dispose(); }
});

test("issue #87：hostCapabilities subagents 三态可区分 drift/missing", async () => {
  const drift = harness({ generation: "rc2", emptySubagents: true });
  try {
    const res = await drift.request("/m/api/diagnostics");
    assert.equal(res.status, 200);
    assert.equal(res.body.checks.hostCapabilities["subagents.catalog"], "drift");
    assert.equal(res.body.checks.hostCapabilities["subagents.interrupt"], "drift");
    assert.deepEqual(res.body.checks.hostGeneration.subagents, { catalog: "none", interrupt: "none" });
  } finally { drift.dispose(); }
  const missing = harness({ generation: "rc2", omitSubagents: true });
  try {
    const res = await missing.request("/m/api/diagnostics");
    assert.equal(res.status, 200);
    assert.equal(res.body.checks.hostCapabilities["subagents.catalog"], "missing");
    assert.equal(res.body.checks.hostCapabilities["subagents.interrupt"], "missing");
  } finally { missing.dispose(); }
});

test("issue #87：hostCapabilities/hostGeneration 按能力探测两代 subagents", async () => {
  const rc2 = harness({ generation: "rc2", descendants: [] });
  try {
    const res = await rc2.request("/m/api/diagnostics");
    assert.equal(res.status, 200);
    assert.equal(res.body.checks.hostCapabilities["subagents.catalog"], "ok");
    assert.equal(res.body.checks.hostCapabilities["subagents.interrupt"], "ok");
    assert.deepEqual(res.body.checks.hostGeneration.subagents, { catalog: "descendants", interrupt: "user" });
  } finally { rc2.dispose(); }
  const rc1 = harness({ generation: "rc1", children: [] });
  try {
    const res = await rc1.request("/m/api/diagnostics");
    assert.equal(res.status, 200);
    assert.equal(res.body.checks.hostCapabilities["subagents.catalog"], "ok");
    assert.equal(res.body.checks.hostCapabilities["subagents.interrupt"], "ok");
    assert.deepEqual(res.body.checks.hostGeneration.subagents, { catalog: "children", interrupt: "parent" });
  } finally { rc1.dispose(); }
});

// issue #112：DSH 0.2.2-rc.2 AgentRegistry 移除 roots()。firstAgent 必须按能力探测，
// 不能直接调用 roots()；catalog/diagnostics 在仅 list 的 registry 下不得 500。

test("issue #112 rc.2：仅 list 的 AgentRegistry → catalog 200、modelsRpc true", async () => {
  const listOnly = { get: (id) => (id === PARENT ? agent : undefined), list: () => [agent] };
  const h = harness({
    agentsRegistry: listOnly,
    rpcValue: { groups: [{ models: [{ id: "m1" }] }] },
  });
  try {
    const catalog = await h.request("/m/api/catalog");
    assert.equal(catalog.status, 200, JSON.stringify(catalog.body));
    assert.notEqual(catalog.body.error, "internal");
    const diagnostics = await h.request("/m/api/diagnostics");
    assert.equal(diagnostics.status, 200);
    assert.equal(diagnostics.body.checks.modelsRpc, true);
  } finally { h.dispose(); }
});

test("issue #112 rc.2：roots 抛错 → 退回 list；catalog/diagnostics 不抛", async () => {
  const rootsThrows = {
    get: () => undefined,
    roots: () => { throw new TypeError("agents.roots is not a function"); },
    list: () => [agent],
  };
  const h = harness({
    agentsRegistry: rootsThrows,
    rpcValue: { groups: [{ models: [{ id: "m1" }] }] },
  });
  try {
    const catalog = await h.request("/m/api/catalog");
    assert.equal(catalog.status, 200, JSON.stringify(catalog.body));
    const diagnostics = await h.request("/m/api/diagnostics");
    assert.equal(diagnostics.status, 200);
    assert.equal(diagnostics.body.checks.modelsRpc, true);
  } finally { h.dispose(); }
});

test("issue #112 rc.2：roots/list 都缺失 → firstAgent undefined 不抛；catalog 200/modelsRpc false", async () => {
  const empty = {};
  const h = harness({ agentsRegistry: empty });
  try {
    const catalog = await h.request("/m/api/catalog");
    assert.equal(catalog.status, 200, JSON.stringify(catalog.body));
    const diagnostics = await h.request("/m/api/diagnostics");
    assert.equal(diagnostics.status, 200);
    assert.equal(diagnostics.body.checks.modelsRpc, false);
  } finally { h.dispose(); }
});

test("issue #112 firstAgent：roots 非空优先；空数组/抛错退回 list；都缺失 undefined", () => {
  const rootFirst = { id: "root-first" };
  const listSecond = { id: "list-second" };
  assert.equal(firstAgent({ roots: () => [rootFirst], list: () => [listSecond] }).id, "root-first");
  assert.equal(firstAgent({ roots: () => [], list: () => [listSecond] }).id, "list-second");
  assert.equal(firstAgent({ roots: () => { throw new Error("drift"); }, list: () => [listSecond] }).id, "list-second");
  assert.equal(firstAgent({ list: () => [listSecond] }).id, "list-second");
  assert.equal(firstAgent({}), undefined);
  assert.equal(firstAgent(null), undefined);
  assert.equal(firstAgent({ roots: () => { throw new Error("drift"); }, list: () => { throw new Error("drift2"); } }), undefined);
  assert.equal(firstAgent({ roots: () => [rootFirst], list: () => { throw new Error("list"); } }).id, "root-first");
});

// issue #112 P2：其余直接 agents.roots() 调用也全部改走 firstAgent；rc.2 仅 list 不崩。
test("issue #112 rc.2：仅 list registry 下 /send 无 sessionId、/send-receipt、合成审批不 TypeError", async () => {
  const sendAgent = {
    ...agent,
    status: "idle",
    followup: async () => undefined,
    steer: async () => undefined,
  };
  const listOnly = { list: () => [sendAgent] };
  const h = harness({ agentsRegistry: listOnly });
  try {
    const send = await h.request("/m/api/send", {
      method: "POST",
      body: JSON.stringify({ text: "hi" }),
    });
    assert.equal(send.status, 200, JSON.stringify(send.body));
    assert.equal(send.body.ok, true);
    assert.equal(send.body.agentId, PARENT);

    const receipt = await h.request(
      "/m/api/send-receipt?requestId=req-12345678",
    );
    assert.equal(receipt.status, 404, "无回执应 404，而不是 rc.2 TypeError 500");
    assert.equal(receipt.body.error, "receipt-not-found");

    const approval = await h.request("/m/api/dev/approval-test", {
      method: "POST",
      body: JSON.stringify({}),
    });
    assert.equal(approval.status, 200, JSON.stringify(approval.body));
    assert.equal(approval.body.synthetic, true);
  } finally { h.dispose(); }
});

test("issue #112 rc.2：roots 抛错时 send/receipt/approval 同样 fallback list", async () => {
  const sendAgent = {
    ...agent,
    status: "idle",
    followup: async () => undefined,
    steer: async () => undefined,
  };
  const rootsThrows = {
    roots: () => { throw new TypeError("drift"); },
    list: () => [sendAgent],
  };
  const h = harness({ agentsRegistry: rootsThrows });
  try {
    const send = await h.request("/m/api/send", {
      method: "POST",
      body: JSON.stringify({ text: "hi" }),
    });
    assert.equal(send.status, 200, JSON.stringify(send.body));
    assert.equal(send.body.agentId, PARENT);
    const receipt = await h.request(
      "/m/api/send-receipt?requestId=req-87654321",
    );
    assert.equal(receipt.status, 404);
    assert.equal(receipt.body.error, "receipt-not-found");
    const approval = await h.request("/m/api/dev/approval-test", {
      method: "POST",
      body: JSON.stringify({}),
    });
    assert.equal(approval.status, 200, JSON.stringify(approval.body));
  } finally { h.dispose(); }
});
