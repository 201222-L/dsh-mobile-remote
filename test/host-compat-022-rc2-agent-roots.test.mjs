/**
 * issue #112：DSH 0.2.2-rc.2 的 AgentRegistry 不再提供 roots()。
 *
 * 本文件只覆盖 firstAgent 的能力探测与 list fallback，以及 catalog/diagnostics/
 * send/receipt/approval 在“仅 list”registry 下不抛 TypeError。
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

function harness({ agentsRegistry = null, rpcValue = null } = {}) {
  const routes = [];
  const provided = new Map();
  const sessionList = [{ id: PARENT, header: { id: PARENT, cwd: "/tmp/proj", createdAt: 1000 } }];
  provided.set("agents", agentsRegistry ?? { get: (id) => (id === PARENT ? agent : undefined), list: () => [agent], roots: () => [] });
  provided.set("sessions", { get: (id) => sessionList.find((s) => s.id === id), list: () => sessionList });
  provided.set("typertGateway", {
    async invokeRpc() { return { ok: true, value: rpcValue ?? { accepted: true } }; },
    async openWireStream() { throw new Error("unused"); },
  });
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
  return { request, dispose() { dispose?.(); } };
}

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

test("issue #112 firstAgent：roots/list getter 抛错也不阻断 fallback", async () => {
  const rootFirst = { id: "root-first" };
  const listSecond = { id: "list-second" };
  const rootsGetterThrows = {
    list: () => [listSecond],
    get roots() { throw new TypeError("roots getter drift"); },
  };
  assert.equal(firstAgent(rootsGetterThrows).id, "list-second");
  const listGetterThrows = {
    roots: () => [rootFirst],
    get list() { throw new TypeError("list getter drift"); },
  };
  assert.equal(firstAgent(listGetterThrows).id, "root-first");
  const bothGettersThrow = {
    get roots() { throw new TypeError("roots getter drift"); },
    get list() { throw new TypeError("list getter drift"); },
  };
  assert.equal(firstAgent(bothGettersThrow), undefined);
  // catalog 走 firstAgent：getter 抛错不能变成 500。
  const h = harness({ agentsRegistry: rootsGetterThrows });
  try {
    const catalog = await h.request("/m/api/catalog");
    assert.equal(catalog.status, 200, JSON.stringify(catalog.body));
    assert.notEqual(catalog.body.error, "internal");
  } finally { h.dispose(); }
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
