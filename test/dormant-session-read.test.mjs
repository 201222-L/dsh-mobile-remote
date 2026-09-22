import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply } from "../lib/index.js";

const SEEDED_ERROR = new Error("seeded session constructor seed must equal its inherited prefix");

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
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken, "content-type": "application/json" };
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

function createHarness({ liveSession, query, agents, agentPresets } = {}) {
	const routes = [];
	const provided = new Map([
		["sessions", { get: () => liveSession }],
		["sessionQuery", query],
	]);
	if (agents !== undefined) provided.set("agents", agents);
	if (agentPresets !== undefined) provided.set("agentPresets", agentPresets);
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on() { return () => {}; },
		effect(callback) {
			const disposer = callback?.();
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
	};
	const disposers = [];
	// apply 返回的 dispose 若无则从 effect 收集
	let dispose = apply(ctx, CONFIG);
	disposers.push(dispose);
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		clean() {
			for (const d of disposers.reverse()) d?.();
		},
	};
}

async function history(route, sessionId) {
	const req = new FakeRequest(`/m/api/history?sessionId=${encodeURIComponent(sessionId)}&limit=100`);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	const body = JSON.parse(res.chunks.join("") || "{}");
	return { status: res.statusCode, body };
}

const assistantEvent = (seq, text) => ({ type: "assistant/message", seq, data: { message: { id: `assistant-${seq}`, content: [{ type: "text", text }] } } });
const userEvent = (seq, text) => ({ type: "user/message", seq, data: { message: { id: `user-${seq}`, content: [{ type: "text", text }] } } });
const surfaceEvent = assistantEvent(100, "surface tail");
const fullEvents = [userEvent(1, "first"), assistantEvent(2, "second")];

test("/history 成功路径：readSession 正常返回事件，不标记 degraded", async () => {
	const calls = [];
	const harness = createHarness({ query: {
		readSession: async (id) => { calls.push(["readSession", id]); return { events: [...fullEvents] }; },
		readSurface: async () => { calls.push(["readSurface", "unexpected"]); return { events: [] }; },
	} });
	try {
		const { status, body } = await history(harness.route, "session-ok");
		assert.equal(status, 200);
		assert.equal(body.ok, true);
		assert.equal(body.degraded, undefined, "正常路径不得标记降级");
		assert.deepEqual(calls, [["readSession", "session-ok"]]);
		assert.ok(body.events.length >= 1);
	} finally {
		harness.clean();
	}
});

test("/history：SESSION_QUERY_SESSION_NOT_FOUND → 404 session-not-found", async () => {
	const harness = createHarness({ query: {
		readSession: async () => {
			throw Object.assign(new Error('session "s" not found'), { code: "SESSION_QUERY_SESSION_NOT_FOUND" });
		},
		readSurface: async () => { throw new Error("must not be called"); },
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 404);
		assert.equal(body.error, "session-not-found");
	} finally {
		harness.clean();
	}
});

test("/history：SESSION_QUERY_CORRUPT_SESSION → 500 session-corrupt", async () => {
	const harness = createHarness({ query: {
		readSession: async () => {
			throw Object.assign(new Error("stored session is corrupt"), { code: "SESSION_QUERY_CORRUPT_SESSION" });
		},
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 500);
		assert.equal(body.error, "session-corrupt");
	} finally {
		harness.clean();
	}
});

test("/history：普通读取错误 → 500 session-read-failed（不再伪装 404）", async () => {
	const harness = createHarness({ query: {
		readSession: async () => { throw new Error("replay exploded"); },
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 500);
		assert.equal(body.error, "session-read-failed");
	} finally {
		harness.clean();
	}
});

test("/history：已知 seeded 核心缺陷 + readSurface → 200 degraded/current-surface", async () => {
	const calls = [];
	const harness = createHarness({ query: {
		readSession: async (id) => { calls.push(["readSession", id]); throw SEEDED_ERROR; },
		readSurface: async (id) => { calls.push(["readSurface", id]); return { events: [surfaceEvent] }; },
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 200);
		assert.equal(body.ok, true);
		assert.equal(body.degraded, true);
		assert.equal(body.historyMode, "current-surface");
		assert.deepEqual(calls, [["readSession", "s"], ["readSurface", "s"]]);
		assert.ok(body.events.length >= 1, "降级路径应返回 surface 事件");
	} finally {
		harness.clean();
	}
});

test("/history：seeded 缺陷但 readSurface 也失败 → 500 session-read-failed", async () => {
	const harness = createHarness({ query: {
		readSession: async () => { throw SEEDED_ERROR; },
		readSurface: async () => { throw new Error("surface failed too"); },
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 500);
		assert.equal(body.error, "session-read-failed");
	} finally {
		harness.clean();
	}
});

test("/history：seeded 缺陷且宿主无 readSurface → 500 session-read-failed", async () => {
	const harness = createHarness({ query: {
		readSession: async () => { throw SEEDED_ERROR; },
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 500);
		assert.equal(body.error, "session-read-failed");
	} finally {
		harness.clean();
	}
});

test("/history：live 会话不走 sessionQuery（readSession 不被调用）", async () => {
	const calls = [];
	const harness = createHarness({
		liveSession: { events: [surfaceEvent], header: { id: "s" } },
		query: {
			readSession: async (id) => { calls.push(id); throw new Error("must not be called for live session"); },
		},
	});
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 200);
		assert.equal(body.degraded, undefined);
		assert.deepEqual(calls, []);
	} finally {
		harness.clean();
	}
});
test("/history：SESSION_QUERY_PERSISTENCE_FAILED → 500 session-read-failed（显式归并）", async () => {
	const harness = createHarness({ query: {
		readSession: async () => {
			throw Object.assign(new Error("failed to read stored session: EIO"), { code: "SESSION_QUERY_PERSISTENCE_FAILED" });
		},
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 500);
		assert.equal(body.error, "session-read-failed");
	} finally {
		harness.clean();
	}
});

test("/history：seeded 降级且 surface 为空（纯 log-only 历史）→ 200 degraded + 空时间线", async () => {
	const harness = createHarness({ query: {
		readSession: async () => { throw SEEDED_ERROR; },
		readSurface: async () => ({ events: [] }),
	} });
	try {
		const { status, body } = await history(harness.route, "s");
		assert.equal(status, 200);
		assert.equal(body.degraded, true);
		assert.equal(body.historyMode, "current-surface");
		assert.deepEqual(body.events, []);
	} finally {
		harness.clean();
	}
});

test("/history：degraded 会话的分页断言确切边界与正文（W2 修正）", async () => {
	const surfaceEvents = [assistantEvent(100, "s10"), assistantEvent(101, "s11"), assistantEvent(102, "s12")];
	const harness = createHarness({ query: {
		readSession: async () => { throw SEEDED_ERROR; },
		readSurface: async () => ({ events: surfaceEvents }),
	} });
	try {
		// before=101 → 严格只返回 seq=100（surface 尾部往前，不回完整日志）
		const req = new FakeRequest(`/m/api/history?sessionId=s&before=101&limit=10`);
		const res = new FakeResponse();
		const finished = new Promise((resolve) => res.once("finish", resolve));
		harness.route(req, res);
		await finished;
		const body = JSON.parse(res.chunks.join("") || "{}");
		assert.equal(res.statusCode, 200);
		assert.equal(body.degraded, true);
		assert.deepEqual(body.events.map((event) => event.seq), [100]);
		assert.equal(body.events[0].data.text, "s10", "summarizeEvent 应从 data.message.content 提取正文");
	} finally {
		harness.clean();
	}
});

test("/history：degraded 会话 before=100 返回空数组（边界）", async () => {
	const surfaceEvents = [assistantEvent(100, "s10"), assistantEvent(101, "s11")];
	const harness = createHarness({ query: {
		readSession: async () => { throw SEEDED_ERROR; },
		readSurface: async () => ({ events: surfaceEvents }),
	} });
	try {
		const req = new FakeRequest(`/m/api/history?sessionId=s&before=100&limit=10`);
		const res = new FakeResponse();
		const finished = new Promise((resolve) => res.once("finish", resolve));
		harness.route(req, res);
		await finished;
		const body = JSON.parse(res.chunks.join("") || "{}");
		assert.equal(res.statusCode, 200);
		assert.deepEqual(body.events.map((event) => event.seq), []);
	} finally {
		harness.clean();
	}
});

test("/history：degraded 会话 after=100 只返回更大的 seq", async () => {
	const surfaceEvents = [assistantEvent(100, "s10"), assistantEvent(101, "s11"), assistantEvent(102, "s12")];
	const harness = createHarness({ query: {
		readSession: async () => { throw SEEDED_ERROR; },
		readSurface: async () => ({ events: surfaceEvents }),
	} });
	try {
		const req = new FakeRequest(`/m/api/history?sessionId=s&after=100&limit=10`);
		const res = new FakeResponse();
		const finished = new Promise((resolve) => res.once("finish", resolve));
		harness.route(req, res);
		await finished;
		const body = JSON.parse(res.chunks.join("") || "{}");
		assert.equal(res.statusCode, 200);
		assert.deepEqual(body.events.map((event) => event.seq), [101, 102]);
	} finally {
		harness.clean();
	}
});

async function sendTo(route, sessionId, body = {}) {
	const payload = { sessionId, text: "hi", ...body };
	const req = new FakeRequest("/m/api/send", "POST", payload);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	queueMicrotask(() => {
		req.emit("data", Buffer.from(JSON.stringify(payload)));
		req.emit("end");
	});
	await finished;
	return { status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") };
}

function dormantAgents(sessionId, resumeCalls) {
	const agent = { id: sessionId, status: "idle", followup: () => {}, steer: () => {} };
	return {
		get: () => undefined,
		roots: () => [],
		resume: async (opts) => { resumeCalls.push(opts); return { agent }; },
	};
}

test("/send：seeded 缺陷时用 listEvents/readEvent 恢复历史配置（model/agent preset 保持）", async () => {
	const resumeCalls = [];
	const query = {
		readSession: async () => { throw SEEDED_ERROR; },
		listEvents: async () => ([
			{ type: "model/selection", seq: 5 },
			{ type: "agent-preset/selected", seq: 6 },
		]),
		readEvent: async ({ seq }) => {
			if (seq === 5) return { target: { type: "model/selection", seq: 5, data: { provider: "p", model: "sea-model", reasoningEffort: "high" } } };
			if (seq === 6) return { target: { type: "agent-preset/selected", seq: 6, data: { agentPreset: "ptc" } } };
			return { target: undefined };
		},
	};
	const harness = createHarness({
		query,
		agents: dormantAgents("s", resumeCalls),
		agentPresets: { defaultId: "standard", resolve: async (id) => ({ id }), mount: async () => {} },
	});
	try {
		const { status, body } = await sendTo(harness.route, "s");
		assert.equal(status, 200);
		assert.equal(body.configDegraded, undefined, "配置恢复成功时不得标记降级");
		assert.equal(resumeCalls.length, 1, "休眠会话应触发 resume");
		assert.deepEqual(resumeCalls[0].agentOptions, { provider: "p", model: "sea-model", reasoningEffort: "high" });
		assert.ok(typeof resumeCalls[0].setup === "function", "preset mount 已按恢复的 agentPreset 装配");
	} finally {
		harness.clean();
	}
});

test("/send：seeded 缺陷且宿主无 listEvents/readEvent → 默认配置 + configDegraded 标记", async () => {
	const resumeCalls = [];
	const harness = createHarness({
		query: { readSession: async () => { throw SEEDED_ERROR; } },
		agents: dormantAgents("s", resumeCalls),
		agentPresets: { defaultId: "standard", resolve: async (id) => ({ id }), mount: async () => {} },
	});
	try {
		const { status, body } = await sendTo(harness.route, "s");
		assert.equal(status, 200);
		assert.equal(body.configDegraded, true, "配置回退默认时必须显式标记");
		assert.equal(resumeCalls.length, 1);
		assert.equal(resumeCalls[0].agentOptions, undefined, "无恢复能力时使用默认模型");
	} finally {
		harness.clean();
	}
});
