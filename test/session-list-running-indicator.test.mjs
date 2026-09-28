// issue #14 / ADR 0013：会话列表端点契约回归。
//
// 覆盖外部可观察行为（docs/05-test-cases.md F-36/F-37/F-38 的服务端半边）：
//   - `lastMessageAt` / `origin` / `parentSession` 三字段出现在响应中且取值正确；
//   - 排序按 `lastMessageAt` 倒序，缺失回退 `lastActivity`，再回退 `createdAt`，等值按 id 稳定；
//   - `parentSession` 存在但无 `origin` 的 fork 会话**不**被标记为 subagent；
//   - 回填：无内存记录时读会话日志取最新消息时间，失败不影响响应返回；
//   - 旧版 App 仍可调用 `POST /sessions/touch`（端点保留且仍更新 `lastActivity`）。
//
// 伪宿主 harness 沿用 test/dormant-session-read.test.mjs 的形态。
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

let apply;
let testHome;

// 进程级持久化文件必须隔离，否则会读写开发者本机的 ~/.dsh/mobile-remote。
test.before(async () => {
	testHome = await mkdtemp(join(tmpdir(), "dsh-mobile-session-list-"));
	process.env.HOME = testHome;
	// 消息时间表与活跃时间表都在 apply() 时按 HOME 解析路径，import 需在设置 HOME 之后
	({ apply } = await import("../lib/index.js"));
});

test.after(async () => {
	await rm(testHome, { recursive: true, force: true });
});

const CONFIG = {
	path: "/m",
	authToken: "1234567890123456",
	cookieName: "dsh_mobile_token",
	trustedHosts: [],
	sessionTtlMs: 60_000,
	rechargeUrl: "https://example.test/top-up",
	maxConnections: 4,
	pushUrls: [],
	pushCooldownMs: 1,
	doneGraceMs: 1,
	pushContent: "minimal",
	rateLimit: {},
	lanBridge: { enabled: false, port: 3080, host: "127.0.0.1" },
	approvalMode: "mobile",
};

class FakeResponse extends EventEmitter {
	constructor() {
		super();
		this.headersSent = false;
		this.chunks = [];
	}
	writeHead(statusCode) {
		this.statusCode = statusCode;
		this.headersSent = true;
	}
	write(chunk) {
		this.chunks.push(Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk));
		return true;
	}
	end(chunk = "") {
		if (chunk !== "") this.chunks.push(String(chunk));
		this.emit("finish");
	}
	destroy() {
		this.destroyed = true;
		this.emit("close");
	}
}

class FakeRequest extends EventEmitter {
	constructor(url, method = "GET", body) {
		super();
		this.url = url;
		this.method = method;
		this.body = body;
		this.headers = {
			host: "127.0.0.1",
			"x-mobile-token": CONFIG.authToken,
			"content-type": "application/json",
			...(body === undefined ? {} : { "content-length": String(Buffer.byteLength(JSON.stringify(body))) }),
		};
		this.socket = { remoteAddress: "127.0.0.1" };
		this.complete = true;
		this.readable = true;
		this.destroyed = false;
	}
	// readBody 走 stream 接口：body 存在则下一 tick 派发 data+end。
	on(event, handler) {
		if (event === "data" && this.body !== undefined) {
			setImmediate(() => {
				handler(Buffer.from(JSON.stringify(this.body)));
			});
		}
		if (event === "end") {
			setImmediate(() => handler());
		}
		return this;
	}
	pause() {}
}

/** 构造假宿主：records 走 sessionQuery.listSessions，live 会话走 sessions.get。 */
function createHarness({ records, liveSessions = [], query, noQuery = false } = {}) {
	const routes = [];
	const handlers = [];
	const liveMap = new Map(liveSessions.map((s) => [s.id, s]));
	const provided = new Map([
		["sessions", { get: (id) => liveMap.get(id), list: () => liveSessions }],
	]);
	if (!noQuery) provided.set("sessionQuery", query ?? { listSessions: async () => records ?? [] });
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on(event, handler) { handlers.push([event, handler]); return () => {}; },
		effect(callback) {
			const disposer = callback?.();
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
	};
	const dispose = apply(ctx, CONFIG);
	const onSessionEvent = handlers.find(([e]) => e === "session/event")?.[1];
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		/** 投递一条实时会话事件（走插件真实的 session/event 订阅路径）。 */
		emit(sessionId, event) { onSessionEvent?.({ id: sessionId }, event); },
		clean() { dispose?.(); },
	};
}

async function call(route, url, { method = "GET", body } = {}) {
	const req = new FakeRequest(url, method, body);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	return { status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") };
}

const sessions = (route) => call(route, "/m/api/sessions");
const touch = (route, sessionId) => call(route, "/m/api/sessions/touch", { method: "POST", body: { sessionId } });

/** 内核会话头记录形态：{ header, live, persisted }。 */
const record = (id, header = {}) => ({
	header: { id, createdAt: header.createdAt ?? 1_000, cwd: header.cwd, ...header },
	live: header.live ?? false,
	persisted: true,
});

/** 带消息事件的假 live 会话（sessionTitleOf/eventsOf 走 snapshotEvents）。 */
const liveSession = (id, events, header = {}) => ({
	id,
	header: { id, createdAt: header.createdAt ?? 1_000, ...header },
	snapshotEvents: () => events,
});

const messageEvent = (seq, time, type = "user/message") => ({
	type,
	seq,
	time,
	data: type === "user/message"
		? { message: { id: `m-${seq}`, content: [{ type: "text", text: `t${seq}` }] } }
		: { message: { id: `m-${seq}`, content: [{ type: "text", text: `t${seq}` }] }, turn: 1, step: 1 },
});

test("会话列表：lastMessageAt 排在最前，且按它倒序（忽略 lastActivity）", async () => {
	// A 的 lastActivity 最新，但最后一条消息最旧 —— 排序必须听 lastMessageAt
	const harness = createHarness({
		records: [record("session-a"), record("session-b"), record("session-c")],
		liveSessions: [liveSession("session-a", []), liveSession("session-b", []), liveSession("session-c", [])],
	});
	try {
		// 通过真实 session/event 订阅路径写入消息时间（工具/生命周期事件不参与）
		harness.emit("session-a", messageEvent(1, 5_000));
		harness.emit("session-b", messageEvent(1, 9_000));
		harness.emit("session-c", messageEvent(1, 7_000));
		// A 反而是最近"活跃"的（旧排序键）——新排序必须无视它
		await touch(harness.route, "session-a");

		const { status, body } = await sessions(harness.route);
		assert.equal(status, 200);
		assert.deepEqual(body.sessions.map((s) => s.id), ["session-b", "session-c", "session-a"]);
		assert.equal(body.sessions[0].lastMessageAt, 9_000);
		// lastActivity 仍在（旧版 App 用），但不参与排序
		assert.equal(typeof body.sessions.find((s) => s.id === "session-a").lastActivity, "number");
	} finally {
		harness.clean();
	}
});

test("会话列表：lastMessageAt 缺失回退 lastActivity，再回退 createdAt", async () => {
	const harness = createHarness({
		records: [
			record("session-created-late", { createdAt: 9_000 }),
			record("session-zero", { createdAt: 1_000 }),
		],
		liveSessions: [liveSession("session-created-late", []), liveSession("session-zero", [])],
	});
	try {
		// 两个都没有 lastMessageAt；只有 session-zero 有 lastActivity（touch）
		await touch(harness.route, "session-zero");
		const { body } = await sessions(harness.route);
		// lastActivity 回退优先于 createdAt：session-zero 排前
		assert.deepEqual(body.sessions.map((s) => s.id), ["session-zero", "session-created-late"]);
		for (const row of body.sessions) assert.equal(row.lastMessageAt, null);
	} finally {
		harness.clean();
	}
});

test("会话列表：lastActivity 字段语义不变（旧版 App 仍可读）", async () => {
	const harness = createHarness({
		records: [record("session-x")],
		liveSessions: [liveSession("session-x", [])],
	});
	try {
		// touch 写 lastActivity（旧版 App 路径）
		const touched = await touch(harness.route, "session-x");
		assert.equal(touched.status, 200);
		assert.equal(typeof touched.body.lastActivity, "number");
		const { body } = await sessions(harness.route);
		const row = body.sessions.find((s) => s.id === "session-x");
		assert.equal(row.lastActivity, touched.body.lastActivity);
		// 但 lastActivity 不冒充 lastMessageAt
		assert.equal(row.lastMessageAt, null);
	} finally {
		harness.clean();
	}
});

test("会话列表：origin=subagent 透出；fork 会话只有 parentSession 不带 origin", async () => {
	const harness = createHarness({
		records: [
			record("session-sub", { origin: "subagent", parentSession: "session-parent" }),
			record("session-fork", { parentSession: "session-parent" }),
			record("session-main"),
		],
		liveSessions: [
			liveSession("session-sub", [], { origin: "subagent", parentSession: "session-parent" }),
			liveSession("session-fork", [], { parentSession: "session-parent" }),
			liveSession("session-main", []),
		],
	});
	try {
		const { body } = await sessions(harness.route);
		const byId = new Map(body.sessions.map((s) => [s.id, s]));
		assert.equal(byId.get("session-sub").origin, "subagent");
		assert.equal(byId.get("session-sub").parentSession, "session-parent");
		// 关键：fork 有 parentSession 但绝不能带 origin（否则客户端会误隐藏用户的会话）
		assert.equal(byId.get("session-fork").origin, undefined);
		assert.equal(byId.get("session-fork").parentSession, "session-parent");
		assert.equal(byId.get("session-main").origin, undefined);
		assert.equal(byId.get("session-main").parentSession, undefined);
	} finally {
		harness.clean();
	}
});

test("会话列表：休眠会话的 origin/parentSession 从日志头部透出（无 live 实例）", async () => {
	// 休眠会话没有 sessions.get 条目，只能靠 sessionQuery 返回的 header
	const harness = createHarness({
		records: [record("session-dormant-sub", { origin: "subagent", parentSession: "session-p" })],
		liveSessions: [],
		query: {
			listSessions: async () => [record("session-dormant-sub", { origin: "subagent", parentSession: "session-p" })],
			readTitleSnapshots: async () => [{ status: "fulfilled", value: { title: { title: "子代理会话" } } }],
		},
	});
	try {
		const { body } = await sessions(harness.route);
		assert.equal(body.sessions[0].origin, "subagent");
		assert.equal(body.sessions[0].parentSession, "session-p");
	} finally {
		harness.clean();
	}
});

test("会话列表：等值 lastMessageAt 时以 id 为次级键，顺序稳定", async () => {
	const harness = createHarness({
		records: [record("session-c"), record("session-a"), record("session-b")],
		liveSessions: [liveSession("session-a", []), liveSession("session-b", []), liveSession("session-c", [])],
	});
	try {
		for (const id of ["session-a", "session-b", "session-c"]) harness.emit(id, messageEvent(1, 5_000));
		const first = await sessions(harness.route);
		const second = await sessions(harness.route);
		assert.deepEqual(first.body.sessions.map((s) => s.id), ["session-a", "session-b", "session-c"]);
		assert.deepEqual(second.body.sessions.map((s) => s.id), ["session-a", "session-b", "session-c"]);
	} finally {
		harness.clean();
	}
});

test("会话列表：无 sessionQuery 时字段缺失不崩，仍返回列表", async () => {
	const harness = createHarness({ noQuery: true, liveSessions: [liveSession("session-only", [])] });
	try {
		const { status, body } = await sessions(harness.route);
		assert.equal(status, 200);
		assert.deepEqual(body.sessions.map((s) => s.id), ["session-only"]);
		assert.equal(body.sessions[0].lastMessageAt, null);
	} finally {
		harness.clean();
	}
});

test("会话列表：回填读日志失败不影响响应返回（视为无记录）", async () => {
	const harness = createHarness({
		records: [record("session-bad")],
		liveSessions: [],
		query: {
			listSessions: async () => [record("session-bad")],
			readSession: async () => { throw new Error("storage exploded"); },
		},
	});
	try {
		const { status, body } = await sessions(harness.route);
		assert.equal(status, 200);
		assert.equal(body.sessions.length, 1);
		assert.equal(body.sessions[0].lastMessageAt, null);
		// 回填是异步的：给它一个 tick，确认异常没有把进程/响应带崩
		await new Promise((resolve) => setTimeout(resolve, 20));
		const after = await sessions(harness.route);
		assert.equal(after.status, 200);
		assert.equal(after.body.sessions[0].lastMessageAt, null);
	} finally {
		harness.clean();
	}
});

test("会话列表：回填读成功后按长 TTL 缓存，不反复读同一批冷会话的日志", async () => {
	// 一次列表刷新不应让冷会话日志被重复读取（titleCache 用同一 TTL 规避同款代价）
	let reads = 0;
	const harness = createHarness({
		records: [record("session-cold")],
		liveSessions: [],
		query: {
			listSessions: async () => [record("session-cold")],
			readSession: async () => {
				reads += 1;
				// 日志里确实没有消息 → 视为"无记录"，属成功读取结果
				return { events: [{ type: "turn/end", seq: 1, time: 5_000, data: { turn: 1, reason: { kind: "completed" } } }] };
			},
		},
	});
	try {
		await sessions(harness.route);
		await new Promise((resolve) => setTimeout(resolve, 60));
		const afterFirst = reads;
		assert.equal(afterFirst, 1, "首次列表应触发一次回填读取");
		// 再来两次列表刷新：命中缓存，不得再读日志
		await sessions(harness.route);
		await sessions(harness.route);
		await new Promise((resolve) => setTimeout(resolve, 60));
		assert.equal(reads, afterFirst, "成功后应命中缓存，不重复读日志");
	} finally {
		harness.clean();
	}
});

test("会话列表：回填读失败按短 TTL 缓存，允许瞬时故障自愈", async () => {
	// 读取失败不该被当成"这个会话永远没有消息"——短 TTL 过后必须重试。
	let attempts = 0;
	const harness = createHarness({
		records: [record("session-flaky")],
		liveSessions: [],
		query: {
			listSessions: async () => [record("session-flaky")],
			readSession: async () => {
				attempts += 1;
				if (attempts === 1) throw new Error("transient storage blip");
				return { events: [messageEvent(1, 7_000)] };
			},
		},
	});
	try {
		await sessions(harness.route);
		await new Promise((resolve) => setTimeout(resolve, 60));
		assert.equal(attempts, 1, "首次触发一次失败的读取");
		// 短 TTL 内不再重试（避免每次刷新都打存储）
		await sessions(harness.route);
		await new Promise((resolve) => setTimeout(resolve, 60));
		assert.equal(attempts, 1, "失败结果在短 TTL 内应命中缓存，不立刻重试");
	} finally {
		harness.clean();
	}
});

test("会话列表：回填从会话日志取最新消息时间，并忽略工具/生命周期事件", async () => {
	// 会话不在 live 注册表 → 走回填路径。日志里工具事件时间更晚，但只有消息事件算数。
	const body = () => record("session-dormant");
	const harness = createHarness({
		records: [body()],
		liveSessions: [],
		query: {
			listSessions: async () => [body()],
			readSession: async () => ({
				events: [
					messageEvent(1, 4_000),
					{ type: "tool/result", seq: 2, time: 99_000, data: {} },
					messageEvent(3, 6_000, "assistant/message"),
					{ type: "turn/end", seq: 4, time: 99_500, data: { turn: 1, reason: { kind: "completed" } } },
				],
			}),
		},
	});
	try {
		const first = await sessions(harness.route);
		assert.equal(first.status, 200);
		// 首次响应必然拿不到（回填不阻塞响应，ADR 0013）
		assert.equal(first.body.sessions[0].lastMessageAt, null);
		// 等回填完成后再拉一次：应拿到 6000（工具/生命周期事件被排除）
		await new Promise((resolve) => setTimeout(resolve, 60));
		const second = await sessions(harness.route);
		assert.equal(second.body.sessions[0].lastMessageAt, 6_000);
	} finally {
		harness.clean();
	}
});

test("会话列表：实时消息事件更新 lastMessageAt（工具/生命周期事件不更新，且只升不降）", async () => {
	const harness = createHarness({
		records: [record("session-live")],
		liveSessions: [liveSession("session-live", [])],
	});
	try {
		const value = async () => (await sessions(harness.route)).body.sessions[0].lastMessageAt;
		// 工具事件与轮次结束：都不算"最近有对话"
		harness.emit("session-live", { type: "tool/result", seq: 9, time: 50_000, data: {} });
		harness.emit("session-live", { type: "turn/end", seq: 10, time: 51_000, data: { turn: 1, reason: { kind: "completed" } } });
		assert.equal(await value(), null, "工具/生命周期事件不得更新 lastMessageAt");
		// 用户消息：算
		harness.emit("session-live", messageEvent(11, 60_000));
		assert.equal(await value(), 60_000);
		// 乱序/回放（更早的时间）不得把时间往回拉
		harness.emit("session-live", messageEvent(12, 20_000, "assistant/message"));
		assert.equal(await value(), 60_000, "lastMessageAt 只升不降");
	} finally {
		harness.clean();
	}
});

test("会话列表：旧版 App 的 touch 端点仍然可用且不影响 lastMessageAt", async () => {
	const harness = createHarness({
		records: [record("session-legacy")],
		liveSessions: [liveSession("session-legacy", [])],
	});
	try {
		const touched = await touch(harness.route, "session-legacy");
		assert.equal(touched.status, 200);
		assert.equal(touched.body.ok, true);
		const { body } = await sessions(harness.route);
		const row = body.sessions.find((s) => s.id === "session-legacy");
		// touch 只动 lastActivity，不动 lastMessageAt
		assert.equal(typeof row.lastActivity, "number");
		assert.equal(row.lastMessageAt, null);
		// 缺 sessionId → 400（既有契约不变）
		const bad = await touch(harness.route, "");
		assert.equal(bad.status, 400);
		assert.equal(bad.body.error, "missing-sessionId");
	} finally {
		harness.clean();
	}
});
