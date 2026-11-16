// issue #109：/m/api/sessions 默认排除「零可见消息」空会话；includeEmpty=1 返回全部。
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply } from "../lib/index.js";

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
  constructor(url, method = "GET") {
    super(); this.url = url; this.method = method;
    this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken };
    this.socket = { remoteAddress: "127.0.0.1" };
  }
}

const recorded = (id, header = {}) => ({ header: { id, createdAt: header.createdAt ?? 1000, cwd: "/tmp/proj", ...header }, live: header.live ?? false, persisted: true });
const liveSession = (id, events, header = {}) => ({ id, header: { id, createdAt: 1000, cwd: "/tmp/proj", ...header }, snapshotEvents: () => events });
const userEvent = (seq, time) => ({ seq, type: "user/message", time, data: { message: { id: `u${seq}`, content: [{ type: "text", text: "hi" }] } } });
const assistantEvent = (seq, time, text = "ok") => ({ seq, type: "assistant/message", time, data: { message: { id: `a${seq}`, content: [{ type: "text", text }] } } });
const configEvent = (seq) => ({ seq, type: "permission/preset", time: 500, data: { preset: "read-only" } });

function harness({ records = [], liveSessions = [], query = null, noQuery = false, archived = [] } = {}) {
  const routes = [];
  const provided = new Map();
  const liveMap = new Map(liveSessions.map((s) => [s.id, s]));
  provided.set("sessions", { get: (id) => liveMap.get(id), list: () => liveSessions });
  if (!noQuery) {
    provided.set("sessionQuery", query ?? {
      listSessions: async () => records,
      async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: `标题 ${id}` } } })); },
    });
  }
  provided.set("workspaceRegistry", {
    list: () => [],
    archivedSessionIds: archived,
    requireState: () => ({ archivedSessionIds: archived }),
    setState: async () => undefined,
    enqueueOperation: async (fn) => fn(),
  });
  const ctx = {
    webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
    logger: { warn() {}, info() {} },
    get(name) { return provided.get(name); }, provide(name, value) { provided.set(name, value); },
    on() { return () => {}; }, effect(cb) { return cb?.() ?? (() => {}); }, inject() {},
  };
  const dispose = apply(ctx, CONFIG);
  const route = routes.find((r) => r.path === "/m/api")?.handler;
  assert.equal(typeof route, "function");
  async function request(url, { method = "GET" } = {}) {
    const req = new Request(url, method);
    const res = new Response();
    const finished = new Promise((resolve) => res.once("finish", resolve));
    route(req, res);
    await finished;
    return { status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") };
  }
  function start(url, { method = "GET" } = {}) {
    const req = new Request(url, method);
    const res = new Response();
    const finished = new Promise((resolve) => res.once("finish", resolve));
    route(req, res);
    return { req, res, finished };
  }
  return { request, start, provide(name, value) { provided.set(name, value); }, dispose() { dispose?.(); } };
}

function fixtureQuery() {
  const events = new Map([
    ["dormant-empty", [configEvent(1)]],
    ["dormant-message", [configEvent(1), userEvent(2, 2000)]],
    ["dormant-tool-only", [{ seq: 3, type: "tool/call", time: 3000, data: { callId: "c" } }]],
  ]);
  return {
    async listSessions() {
      return ["live-empty", "live-message", "dormant-empty", "dormant-message", "dormant-tool-only", "archived-empty"]
        .map((id) => recorded(id, { live: id.startsWith("live-") }));
    },
    async readSession(id) { return { events: events.get(id) ?? [] }; },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: `标题 ${id}` } } })); },
  };
}

test("issue #109：默认排除配置空会话；tool-only 保留；includeEmpty=1 返回全部", async () => {
  const h = harness({
    liveSessions: [
      liveSession("live-empty", [configEvent(1)]),
      liveSession("live-message", [userEvent(1, 1000)]),
      liveSession("fallback-empty-live", []),
    ],
    archived: ["archived-empty"],
  });
  h.provide("sessionQuery", fixtureQuery());
  try {
    const def = await h.request("/m/api/sessions");
    assert.equal(def.status, 200, JSON.stringify(def.body));
    const ids = def.body.sessions.map((s) => s.id);
    assert.deepEqual(ids.sort(), ["dormant-message", "dormant-tool-only", "live-message"]);
    assert.ok(!ids.includes("dormant-empty"));
    assert.ok(ids.includes("dormant-tool-only"), "tool-only 是有价值的会话，不得当空会话删除");
    assert.ok(!ids.includes("archived-empty"));
    // 排序：dormant-message 2000 > live-message 1000；tool-only 无消息时间按 createdAt 回退。
    assert.deepEqual(def.body.sessions.map((s) => s.id), ["dormant-message", "dormant-tool-only", "live-message"]);
    for (const row of def.body.sessions) assert.ok(typeof row.title === "string" && row.title !== "", "标题不得回退为空");
    assert.match(def.body.sessions.find((s) => s.id === "dormant-message").title, /标题 /);

    const all = await h.request("/m/api/sessions?includeEmpty=1");
    assert.equal(all.status, 200);
    const allIds = all.body.sessions.map((s) => s.id).sort();
    assert.deepEqual(allIds, [
      "archived-empty", "dormant-empty", "dormant-message", "dormant-tool-only", "live-empty", "live-message",
    ]);
    assert.equal(all.body.sessions.find((s) => s.id === "archived-empty").archived, true);

    for (const value of ["0", "true", "", "yes"]) {
      const got = await h.request(`/m/api/sessions?includeEmpty=${encodeURIComponent(value)}`);
      assert.ok(!got.body.sessions.some((s) => s.id === "dormant-empty"), `includeEmpty=${value} 应按 false`);
    }
  } finally { h.dispose(); }
});

test("issue #109：旧宿主无 sessionQuery（fallback 分支）同样过滤空会话", async () => {
  const h = harness({
    noQuery: true,
    liveSessions: [
      liveSession("empty-live", [configEvent(1)]),
      liveSession("message-live", [assistantEvent(2, 2000)]),
    ],
  });
  try {
    const def = await h.request("/m/api/sessions");
    assert.deepEqual(def.body.sessions.map((s) => s.id), ["message-live"]);
    const all = await h.request("/m/api/sessions?includeEmpty=1");
    assert.deepEqual(all.body.sessions.map((s) => s.id).sort(), ["empty-live", "message-live"]);
  } finally { h.dispose(); }
});

test("issue #109：已释放/归档空会话默认隐藏；有消息的归档会话保留 archived 标记", async () => {
  const h = harness({ archived: ["empty-archived", "message-archived"] });
  h.provide("sessionQuery", {
    async listSessions() {
      return [recorded("empty-archived"), recorded("message-archived")];
    },
    async readSession(id) {
      return { events: id === "message-archived" ? [userEvent(1, 5000)] : [configEvent(1)] };
    },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  try {
    const def = await h.request("/m/api/sessions");
    assert.deepEqual(def.body.sessions.map((s) => s.id), ["message-archived"]);
    assert.equal(def.body.sessions[0].archived, true);
    const all = await h.request("/m/api/sessions?includeEmpty=1");
    assert.deepEqual(all.body.sessions.map((s) => s.id).sort(), ["empty-archived", "message-archived"]);
  } finally { h.dispose(); }
});

test("issue #109：回填失败/未知的会话不误删（宁可多显示）", async () => {
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return [recorded("unknown")]; },
    async readSession() { throw new Error("persistence failed"); },
    async readTitleSnapshots(ids) { return ids.map(() => ({ status: "rejected" })); },
  });
  try {
    const def = await h.request("/m/api/sessions");
    assert.deepEqual(def.body.sessions.map((s) => s.id), ["unknown"],
      "无法确认空/非空时保留，不能把有消息会话误删");
  } finally { h.dispose(); }
});

test("issue #109 P2：time 缺失仍可见；空 assistant/系统注入不算可见消息", async () => {
  const h = harness({
    noQuery: true,
    liveSessions: [
      liveSession("time-missing", [{ seq: 1, type: "user/message", data: { message: { id: "u", content: [{ type: "text", text: "hi" }] } } }]),
      liveSession("empty-assistant", [assistantEvent(2, 2000, "")]),
      liveSession("injected", [{ seq: 3, type: "user/message", time: 3000, data: { message: { id: "i", content: [{ type: "text", text: "plugin" }] }, source: { kind: "plugin" } } }]),
      liveSession("assistant-ok", [assistantEvent(4, 4000, "answer")]),
    ],
  });
  try {
    const def = await h.request("/m/api/sessions");
    assert.deepEqual(def.body.sessions.map((s) => s.id).sort(), ["assistant-ok", "time-missing"]);
  } finally { h.dispose(); }
});

test("issue #109 P2：旧空缓存不删——先空后出现消息，下一次请求仍保留", async () => {
  let events = [configEvent(1)];
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return [recorded("target")]; },
    async readSession() { return { events }; },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  try {
    const first = await h.request("/m/api/sessions");
    assert.deepEqual(first.body.sessions, [], "旧空会话默认隐藏");
    events = [{ seq: 2, type: "user/message", data: { message: { id: "u", content: [{ type: "text", text: "new" }] } } }];
    const second = await h.request("/m/api/sessions");
    assert.deepEqual(second.body.sessions.map((s) => s.id), ["target"],
      "本次读取到可见消息时不得被旧 ok 缓存误删（time 缺失也要保留）");
  } finally { h.dispose(); }
});

test("issue #109 P2：120 会话超预算不删、总时长有硬上限、读取并发≤4", async () => {
  let active = 0;
  let maxActive = 0;
  let reads = 0;
  const records = Array.from({ length: 120 }, (_, i) => recorded(`s-${i}`));
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return records; },
    readSession() {
      reads += 1;
      active += 1;
      maxActive = Math.max(maxActive, active);
      // 永不 resolve 的读：必须被单次 deadline/总预算 race 掉，不能挂住请求。
      return new Promise(() => {});
    },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  try {
    const started = performance.now();
    const res = await h.request("/m/api/sessions");
    const elapsed = performance.now() - started;
    assert.equal(res.status, 200);
    assert.equal(res.body.sessions.length, 120, "未确认的会话必须保留，不得因超预算删除");
    assert.ok(elapsed >= 2300 && elapsed < 4500, `总预算应约 2.5s，实际 ${elapsed}`);
    assert.ok(reads >= 1, "至少进入读取");
    // 并发上限由独立有限延迟用例精确断言；这里挂起读的底层 promise 无法取消，
    // active 计数会保留到进程结束，故只验证硬时限+不删。
  } finally { h.dispose(); }
});

test("issue #109 P2：同步可见性读取并发≤4（有限延迟场景）", async () => {
  let active = 0;
  let maxActive = 0;
  const records = Array.from({ length: 120 }, (_, i) => recorded(`c-${i}`));
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return records; },
    async readSession() {
      active += 1;
      maxActive = Math.max(maxActive, active);
      await new Promise((resolve) => setTimeout(resolve, 20));
      active -= 1;
      return { events: [userEvent(1, 1000)] };
    },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  try {
    const res = await h.request("/m/api/sessions");
    assert.equal(res.status, 200);
    assert.equal(res.body.sessions.length, 120);
    assert.ok(maxActive <= 4, `并发上限应为 4，实际 ${maxActive}`);
  } finally { h.dispose(); }
});

test("issue #109 P2：请求取消后不再写响应（readSession 挂起也不无限等待）", async () => {
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return [recorded("cancelled")]; },
    readSession() { return new Promise(() => {}); },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  try {
    const pending = h.start("/m/api/sessions");
    await new Promise((resolve) => setTimeout(resolve, 60));
    pending.res.emit("close"); // 客户端断开
    let finished = false;
    pending.finished.then(() => { finished = true; });
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert.equal(finished, false, "断开后不得写响应");
  } finally { h.dispose(); }
});

test("issue #109 实机回归：300+ 休眠会话用 persistence metadata 过滤，不做逐个 readSession", async () => {
  const empty = Array.from({ length: 324 }, (_, i) => {
    const id = `session-empty-${i}`;
    return { snapshot: { header: { id, createdAt: 1000, cwd: "/tmp" }, sizeBytes: 330 + (i % 5) }, record: recorded(id) };
  });
  const visible = Array.from({ length: 30 }, (_, i) => {
    const id = `session-visible-${i}`;
    return { snapshot: { header: { id, createdAt: 2000 + i, cwd: "/tmp" }, sizeBytes: 40000 + i }, record: recorded(id) };
  });
  const timeMissing = Array.from({ length: 7 }, (_, i) => {
    const id = `session-time-missing-${i}`;
    return { snapshot: { header: { id, createdAt: 3000 + i, cwd: "/tmp" }, sizeBytes: 50000 + i }, record: recorded(id) };
  });
  const all = [...empty, ...visible, ...timeMissing];
  let reads = 0;
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return all.map((e) => e.record); },
    async readSession() { reads += 1; throw new Error("must not read 300+ logs"); },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id.startsWith("session-empty-") ? id : `标题 ${id}` } } })); },
  });
  h.provide("sessionPersistence", { list: async () => all.map((e) => e.snapshot) });
  try {
    const started = performance.now();
    const def = await h.request("/m/api/sessions");
    const elapsed = performance.now() - started;
    assert.equal(def.status, 200);
    assert.equal(def.body.sessions.length, 37, "324 个小文件空会话必须默认隐藏，37 个正常保留（生产 JSONL 无 eventCount）");
    assert.ok(def.body.sessions.every((row) => !row.id.startsWith("session-empty-")), "空会话不得出现");
    assert.ok(reads <= 4, `metadata 足够时不得逐个 readSession（后台回填至多4个在途，实际 ${reads}）`);
    assert.ok(elapsed < 1000, `300+ 批量应 <1s，实际 ${elapsed}ms`);
    const byId = new Map(def.body.sessions.map((row) => [row.id, row]));
    assert.ok(byId.has("session-time-missing-0"), "time 缺失但非空会话保留");
    assert.match(byId.get("session-visible-0").title, /标题 /);

    const allRes = await h.request("/m/api/sessions?includeEmpty=1");
    assert.equal(allRes.body.sessions.length, 361);
  } finally { h.dispose(); }
});

test("issue #109：sizeBytes 小才判空；size 大保留，size 缺失走有界读确认", async () => {
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return [recorded("small"), recorded("large"), recorded("tool-only"), recorded("unknown-size")]; },
    async readSession() { return { events: [configEvent(1)] }; },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  h.provide("sessionPersistence", {
    list: async () => [
      { header: { id: "small", createdAt: 1 }, sizeBytes: 400 },
      { header: { id: "large", createdAt: 1 }, sizeBytes: 40000 },
      // 事件数少但文件大：可能含工具调用/长参数，不能只按 eventCount 判空。
      { header: { id: "tool-only", createdAt: 1 }, eventCount: 5, sizeBytes: 40000 },
      { header: { id: "unknown-size", createdAt: 1 } },
    ],
  });
  try {
    const def = await h.request("/m/api/sessions");
    const ids = def.body.sessions.map((s) => s.id).sort();
    assert.deepEqual(ids, ["large", "tool-only"], "size 小才判空；eventCount 小但文件大保留；size 缺失读日志确认空后隐藏");
    const all = await h.request("/m/api/sessions?includeEmpty=1");
    assert.equal(all.body.sessions.length, 4);
  } finally { h.dispose(); }
});

test("issue #111 P2：1024–2048B 灰区回退 tool-aware readSession（小 tool-only/only-user 不误删）", async () => {
  const sessions = {
    "grey-tool-only": { sizeBytes: 1_500, events: [{ type: "tool/call", seq: 1 }, { type: "tool/result", seq: 2 }] },
    "grey-only-user": { sizeBytes: 1_300, events: [userEvent(1, 1000)] },
    "grey-empty": { sizeBytes: 1_600, events: [configEvent(1), configEvent(2)] },
    "small-empty": { sizeBytes: 700, events: [configEvent(1)] },
    "big-visible": { sizeBytes: 40_000, events: [assistantEvent(1, 1000, "hi")] },
  };
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return Object.keys(sessions).map((id) => recorded(id)); },
    async readSession(id) { return { events: sessions[id].events }; },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  h.provide("sessionPersistence", {
    list: async () => Object.entries(sessions).map(([id, s]) => ({ header: { id, createdAt: 1 }, sizeBytes: s.sizeBytes })),
  });
  try {
    const def = await h.request("/m/api/sessions");
    assert.deepEqual(def.body.sessions.map((s) => s.id).sort(), ["big-visible", "grey-only-user", "grey-tool-only"]);
    const all = await h.request("/m/api/sessions?includeEmpty=1");
    assert.equal(all.body.sessions.length, 5);
  } finally { h.dispose(); }
});

test("issue #111 P2：sessionPersistence.list 失败/超时 → 回退有界 readSession，不 500 不误删", async () => {
  const h = harness();
  h.provide("sessionQuery", {
    async listSessions() { return [recorded("empty"), recorded("visible")]; },
    async readSession(id) { return { events: id === "visible" ? [userEvent(1, 1000)] : [configEvent(1)] }; },
    async readTitleSnapshots(ids) { return ids.map((id) => ({ status: "fulfilled", value: { title: { title: id } } })); },
  });
  h.provide("sessionPersistence", { list: async () => { throw new Error("metadata unavailable"); } });
  try {
    const def = await h.request("/m/api/sessions");
    assert.equal(def.status, 200);
    assert.deepEqual(def.body.sessions.map((s) => s.id), ["visible"]);
  } finally { h.dispose(); }
});
