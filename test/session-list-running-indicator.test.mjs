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
let planMessageTimePrune;
let CORPUS_FRESH_MS;
let testHome;

// 进程级持久化文件必须隔离，否则会读写开发者本机的 ~/.dsh/mobile-remote。
test.before(async () => {
	testHome = await mkdtemp(join(tmpdir(), "dsh-mobile-session-list-"));
	process.env.HOME = testHome;
	// 消息时间表与活跃时间表都在 apply() 时按 HOME 解析路径，import 需在设置 HOME 之后
	({ apply, planMessageTimePrune, CORPUS_FRESH_MS } = await import("../lib/index.js"));
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
function createHarness({ records, liveSessions = [], query, noQuery = false, agents = null, gateway = null } = {}) {
	const routes = [];
	const handlers = [];
	const liveMap = new Map(liveSessions.map((s) => [s.id, s]));
	const provided = new Map([
		["sessions", { get: (id) => liveMap.get(id), list: () => liveSessions }],
	]);
	if (!noQuery) provided.set("sessionQuery", query ?? { listSessions: async () => records ?? [] });
	if (agents) provided.set("agents", agents);
	if (gateway) provided.set("typertGateway", gateway);
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

const messageEvent = (seq, time, type = "user/message", { source } = {}) => ({
	type,
	seq,
	time,
	data: type === "user/message"
		? { id: `m-${seq}`, role: "user", content: [{ type: "text", text: `t${seq}` }], ...(source ? { source } : {}) }
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

test("会话列表：系统注入与空助手消息不计入 lastMessageAt（只认可见对话消息）", async () => {
	const harness = createHarness({
		records: [record("session-inj")],
		liveSessions: [liveSession("session-inj", [])],
	});
	try {
		const value = async () => (await sessions(harness.route)).body.sessions[0].lastMessageAt;
		// 真人提问：算
		harness.emit("session-inj", messageEvent(1, 1000));
		assert.equal(await value(), 1000);
		// 系统注入（source.kind = plugin）：不算——App 普通模式下不渲染它
		harness.emit("session-inj", {
			type: "user/message", seq: 2, time: 5000,
			data: { id: "inj-1", role: "user", content: [{ type: "text", text: "[SCHEDULE REMINDER] ..." }], source: { kind: "plugin", plugin: "x" } },
		});
		assert.equal(await value(), 1000, "插件注入不得推高 lastMessageAt");
		// agent-instructions / tool 注入同样不算
		for (const kind of ["agent-instructions", "tool"]) {
			harness.emit("session-inj", {
				type: "user/message", seq: 3, time: 6000,
				data: { id: `inj-${kind}`, role: "user", content: [{ type: "text", text: "injected" }], source: { kind } },
			});
		}
		assert.equal(await value(), 1000, "其它来源注入也不得推高");
		// 正文为空的 assistant 中间产物（纯工具阶段）：不算
		harness.emit("session-inj", {
			type: "assistant/message", seq: 4, time: 7000,
			data: { turn: 1, step: 1, message: { id: "a-empty", content: [{ type: "tool-call", name: "shell" }] } },
		});
		assert.equal(await value(), 1000, "空正文 assistant 中间产物不得推高");
		// 有正文的 assistant：算
		harness.emit("session-inj", {
			type: "assistant/message", seq: 5, time: 8000,
			data: { turn: 1, step: 1, message: { id: "a-real", content: [{ type: "text", text: "回答" }] } },
		});
		assert.equal(await value(), 8000, "有正文的助手回复必须计入");
	} finally {
		harness.clean();
	}
});

test("会话列表：回填同样只认可见对话消息（注入/空助手不影响排序键）", async () => {
	const rows = [record("session-dormant-inj")];
	const harness = createHarness({
		records: rows,
		liveSessions: [],
		query: {
			listSessions: async () => rows,
			readSession: async () => ({
				events: [
					messageEvent(1, 3000),
					// 更晚、但都是不可见记录
					{ type: "user/message", seq: 2, time: 9000, data: { id: "i", role: "user", content: [{ type: "text", text: "x" }], source: { kind: "plugin" } } },
					{ type: "assistant/message", seq: 3, time: 9500, data: { turn: 1, step: 1, message: { id: "e", content: [{ type: "tool-call", name: "t" }] } } },
				],
			}),
		},
	});
	try {
		await sessions(harness.route);
		await new Promise((resolve) => setTimeout(resolve, 60));
		const { body } = await sessions(harness.route);
		assert.equal(body.sessions[0].lastMessageAt, 3000, "回填必须跳过注入与空助手消息");
	} finally {
		harness.clean();
	}
});

test("会话列表：模型 / reasoning effort 选择不改变排序（F-38 补充回归）", async () => {
	// 用户实测项：切换模型或 effort 后返回列表，排序位置保持不变。
	// 这些事件都不是可见对话消息，因此不得触碰 lastMessageAt。
	const harness = createHarness({
		records: [record("session-cfg")],
		liveSessions: [liveSession("session-cfg", [])],
	});
	try {
		const value = async () => (await sessions(harness.route)).body.sessions[0].lastMessageAt;
		harness.emit("session-cfg", messageEvent(1, 2000));
		assert.equal(await value(), 2000);
		for (const ev of [
			{ type: "model/selection", seq: 2, time: 8000, data: { provider: "openai", model: "gpt" } },
			{ type: "model/selection", seq: 3, time: 8100, data: { provider: "deepseek-official", model: "deepseek-v4-pro", reasoningEffort: "max" } },
			{ type: "permission/preset", seq: 4, time: 8200, data: { preset: "read-only" } },
			{ type: "agent-preset/selected", seq: 5, time: 8300, data: { agentPreset: "standard" } },
		]) {
			harness.emit("session-cfg", ev);
		}
		assert.equal(await value(), 2000, "配置类事件不得改变排序键");
	} finally {
		harness.clean();
	}
});

test("/subagents：父 agent 活跃时走内核 RPC（既有行为不变）", async () => {
	// 伪内核网关：确定性地断言「活跃父走 subagent.list RPC」而非持久化枚举
	const rpcCalls = [];
	const harness = createHarness({
		records: [record("session-parent")],
		liveSessions: [],
		agents: {
			get: (id) => (id === "session-parent" ? { id, session: { id } } : undefined),
			list: () => [],
		},
		gateway: {
			invokeRpc: async (endpoint, { args }) => {
				rpcCalls.push({ endpoint, args });
				return {
					ok: true,
					value: { parentAvailable: true, entries: [{ id: "live-child", kind: "child", activity: "running", label: "活跃子代理" }] },
				};
			},
		},
	});
	try {
		const { status, body } = await call(harness.route, "/m/api/subagents?parentSessionId=session-parent");
		assert.equal(status, 200);
		assert.equal(body.parentAvailable, true);
		assert.deepEqual(body.subagents, [
			{ id: "live-child", kind: "child", status: "running", title: "活跃子代理" },
		]);
		assert.equal(rpcCalls.length, 1, "活跃父必须走内核 RPC");
		// subagent.list 的适配器直接传 { parentSessionId }（不经 request 包装，见 RPC_PAYLOAD_ADAPTER）
		assert.deepEqual(rpcCalls[0].args, { parentSessionId: "session-parent" },
			"RPC payload 形状不得改变（subagent.list ← parentSessionId）");
		assert.equal(rpcCalls[0].endpoint, "subagents/list", "RPC 端点名按内核真名映射");
	} finally {
		harness.clean();
	}
});

test("/subagents：休眠/归档父会话仍可列出子代理（US35，不依赖父 agent 活跃）", async () => {
	// 父会话已休眠：内核内存无 agent 实例（agents.get 恒 undefined）
	const harness = createHarness({
		records: [
			record("session-parent"),
			record("session-child-1", { origin: "subagent", parentSession: "session-parent" }),
			record("session-child-2", { origin: "subagent", parentSession: "session-parent" }),
			// 用户 fork：有 parentSession 但**无** origin → 不是子代理，不得列出
			record("session-fork", { parentSession: "session-parent" }),
			// 别人的子代理
			record("session-other-child", { origin: "subagent", parentSession: "session-other" }),
		],
		liveSessions: [],
		agents: { get: () => undefined, list: () => [] },
		query: {
			listSessions: async () => [
				record("session-parent"),
				record("session-child-1", { origin: "subagent", parentSession: "session-parent" }),
				record("session-child-2", { origin: "subagent", parentSession: "session-parent" }),
				record("session-fork", { parentSession: "session-parent" }),
				record("session-other-child", { origin: "subagent", parentSession: "session-other" }),
			],
			readTitleSnapshots: async (ids) => ids.map((id) => ({ status: "fulfilled", value: { title: { title: `标题 ${id}` } } })),
		},
	});
	try {
		const { status, body } = await call(harness.route, "/m/api/subagents?parentSessionId=session-parent");
		assert.equal(status, 200, "休眠父会话必须仍可列出子代理");
		assert.equal(body.ok, true);
		assert.equal(body.parentAvailable, false, "父会话无活跃 agent 应如实标注");
		const ids = body.subagents.map((e) => e.id).sort();
		assert.deepEqual(ids, ["session-child-1", "session-child-2"], "只列该父会话的子代理，排除 fork 与别人的子代理");
		for (const e of body.subagents) assert.equal(typeof e.title, "string");
	} finally {
		harness.clean();
	}
});

test("/subagents：嵌套子代理（子代理自身作为父）同样可列出", async () => {
	const rows = [
		record("session-parent"),
		record("session-child", { origin: "subagent", parentSession: "session-parent" }),
		record("session-grandchild", { origin: "subagent", parentSession: "session-child" }),
	];
	const harness = createHarness({
		records: rows,
		liveSessions: [],
		agents: { get: () => undefined, list: () => [] },
		query: { listSessions: async () => rows, readTitleSnapshots: async (ids) => ids.map(() => ({ status: "rejected" })) },
	});
	try {
		const { status, body } = await call(harness.route, "/m/api/subagents?parentSessionId=session-child");
		assert.equal(status, 200);
		assert.deepEqual(body.subagents.map((e) => e.id), ["session-grandchild"]);
	} finally {
		harness.clean();
	}
});

test("/subagents：会话确实不存在时仍返回 404", async () => {
	const harness = createHarness({
		records: [record("session-someone-else")],
		liveSessions: [],
		agents: { get: () => undefined, list: () => [] },
	});
	try {
		const { status, body } = await call(harness.route, "/m/api/subagents?parentSessionId=session-missing");
		assert.equal(status, 404);
		assert.equal(body.error, "session-not-found");
	} finally {
		harness.clean();
	}
});

test("/subagents：缺 parentSessionId → 400（既有契约不变）", async () => {
	const harness = createHarness({ records: [], liveSessions: [], agents: { get: () => undefined } });
	try {
		const { status, body } = await call(harness.route, "/m/api/subagents");
		assert.equal(status, 400);
		assert.equal(body.error, "parentSessionId-required");
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

// ── 存在性剪枝（issue #14 复核 #5）：纯函数直测，不依赖定时器 ──

test("剪枝：会话仍存在时保留排序键（哪怕是很久以前的会话）", () => {
	const now = 1_000_000_000;
	const plan = planMessageTimePrune({
		messageTimeIds: ["old-but-alive"],
		corpusIds: new Set(["old-but-alive"]),
		corpusObservedAt: now - 1000,
		now,
	});
	assert.deepEqual(plan.remove, [], "存在的旧会话不得被剪掉");
	assert.equal(plan.misses.size, 0);
});

test("剪枝：会话确实消失时连续两次观测才删除", () => {
	const now = 1_000_000_000;
	const corpus = new Set(["alive"]);
	// 第一次观测缺失 → 只登记待确认，不删
	const first = planMessageTimePrune({
		messageTimeIds: ["gone", "alive"],
		corpusIds: corpus,
		corpusObservedAt: now - 1000,
		now,
	});
	assert.deepEqual(first.remove, []);
	assert.deepEqual([...first.misses], ["gone"]);
	// 第二次仍缺失 → 确认删除
	const second = planMessageTimePrune({
		messageTimeIds: ["gone", "alive"],
		corpusIds: corpus,
		corpusObservedAt: now - 1000,
		misses: first.misses,
		now,
	});
	assert.deepEqual(second.remove, ["gone"]);
});

test("剪枝：会话重新出现则清除待确认（不误删）", () => {
	const now = 1_000_000_000;
	const plan = planMessageTimePrune({
		messageTimeIds: ["back"],
		corpusIds: new Set(["back"]),
		corpusObservedAt: now - 1000,
		misses: new Set(["back"]), // 上一轮曾判缺失
		now,
	});
	assert.deepEqual(plan.remove, []);
	assert.equal(plan.misses.has("back"), false, "回归的会话必须从待删集合移除");
});

test("剪枝：从未观测过完整语料时不剪枝（旧内核 / 读取失败）", () => {
	const now = 1_000_000_000;
	const plan = planMessageTimePrune({
		messageTimeIds: ["a", "b"],
		corpusIds: new Set(),
		corpusObservedAt: 0,
		now,
	});
	assert.deepEqual(plan.remove, [], "没有语料观测就不得删任何键");
	assert.equal(plan.misses.size, 0);
});

test("剪枝：观测过旧时不剪枝，并清空陈旧待确认（避免下一轮误删）", () => {
	const now = 1_000_000_000;
	const plan = planMessageTimePrune({
		messageTimeIds: ["stale"],
		corpusIds: new Set(["other"]),
		corpusObservedAt: now - CORPUS_FRESH_MS - 1, // 刚好过期
		misses: new Set(["stale"]), // 上一轮留下的待确认
		now,
	});
	assert.deepEqual(plan.remove, [], "过旧观测不得触发删除");
	assert.equal(
		plan.misses.size,
		0,
		"必须清空陈旧待确认，否则下轮新鲜观测会把它当成第二次确认而误删",
	);
});
