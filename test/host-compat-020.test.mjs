/**
 * 宿主代际兼容回归测试（v3.1.6 / issue #19 / ADR 0017）。
 *
 * 为什么需要**两代宿主夹具**：本次四处宿主接口不兼容的共同形态是
 * "服务仍然存在、调用也不报错、但语义已经变了"（能力语义漂移）。
 * 既有极简假 ctx 只能表达"服务在不在"，**表达不了**这一形态——所以那套夹具
 * 对本次的四处问题一处也测不出来。
 *
 * 关键约束：本仓只对 **0.2.x 做真实宿主端到端验证**（本机宿主即 0.2.x），
 * 0.1.x 那条分支**永远不会被真实宿主执行到**。因此本文件的 legacy 部分是
 * 0.1.x 路径的**唯一保护**：它必须让分支真的被执行，而不是只断言参数形状——
 * `settings.get` 那类故障是被 try/catch 吞掉的，形状断言挡不住。
 *
 * 夹具按**真实签名**复刻两代差异（含形参个数——插件正是按 `.length` 判别事件流参数位次的）。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter, getEventListeners } from "node:events";
import {
	apply,
	jobsNeedsSessionId,
	jobsCallerFor,
	readSettingsSection,
	wireStreamTakesControl,
	capabilityState,
} from "../lib/index.js";

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
	approvalMode: "both",
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
	constructor(url, method = "GET") {
		super();
		this.url = url;
		this.method = method;
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken, "content-type": "application/json" };
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

async function call(route, { url, method = "GET", body } = {}) {
	const req = new FakeRequest(url, method);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	if (body !== undefined) {
		queueMicrotask(() => {
			req.emit("data", Buffer.from(JSON.stringify(body), "utf8"));
			req.emit("end");
		});
	}
	await finished;
	return { status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") };
}

const AGENT = { id: "session-A", session: { id: "session-A", header: { cwd: "/tmp/proj" } }, status: "idle" };

/**
 * 两代宿主夹具。`generation` 决定四处差异的**真实形状**。
 * 所有发往宿主的调用都被记录，断言只针对"插件传出去的东西"与"端点返回的东西"——
 * 不触碰插件内部实现。
 */
function createHarness({ generation, frames = [], endAfterFrames = false }) {
	const modern = generation === "0.2.0";
	const routes = [];
	const provided = new Map();
	const logs = { warn: [], info: [] };
	const seen = {
		jobsList: [], jobsKill: [], settingsGet: [], settingsDescribe: 0,
		eventsSubscribe: [], wireStreamArgs: [], legacyJobCallbacks: 0,
		framesDelivered: 0,
	};

	// ── 任务服务：0.1.x 收 Agent 对象 + 两个回调；0.2.x 收 SessionId 字符串 + 统一事件流 ──
	const jobs = {
		list(caller) { seen.jobsList.push(caller); return []; },
		kill(id, caller, reason) { seen.jobsKill.push({ id, caller, reason }); return "requested"; },
	};
	if (modern) {
		jobs.events = {
			subscribe(filter, listener) { seen.eventsSubscribe.push({ filter, listener }); return () => {}; },
		};
	} else {
		jobs.onJobsChanged = (cb) => { seen.legacyJobCallbacks += 1; return () => {}; };
		jobs.onJobDone = (cb) => { seen.legacyJobCallbacks += 1; return () => {}; };
	}

	// ── 设置服务：0.1.x 有 get(ns)；0.2.x 只有 describe() ──
	const settings = modern
		? { describe() { seen.settingsDescribe += 1; return [{ ns: "providers", value: { baseURL: "https://x.test" } }]; } }
		: { get(ns) { seen.settingsGet.push(ns); return { baseURL: "https://x.test" }; } };

	// ── 事件流：形参个数即代际（插件按 .length 判别信号位次）──
	// 默认**保持打开**直到 signal 中止：真实 $events 流不会自行结束。若让生成器直接结束，
	// 插件会（正确地）按"断开"处理并进入退避重连——那是另一条路径，会让测试挂着定时器。
	// `endAfterFrames: true` 则刻意在发完帧后结束，用来**驱动重连回放**
	// （宿主在新连接建立时会重投未结算事件），这是评审 WARNING 2 的复现前提。
	const holdOpenUntilAborted = (signal) => new Promise((resolve) => {
		if (!signal || signal.aborted) return resolve();
		signal.addEventListener("abort", () => resolve(), { once: true });
	});
	const emitFrames = async function* (signal) {
		yield { type: "ready", clientId: "c-1" };
		for (const frame of frames) {
			seen.framesDelivered += 1;
			yield frame;
		}
		if (!endAfterFrames) await holdOpenUntilAborted(signal);
	};
	const gateway = {
		async invokeRpc() { return { ok: true, value: {} }; },
		async dispatchRpc() { return { ok: true, value: undefined }; },
	};
	if (modern) {
		// 0.2.0 真实签名：signal 是第 5 个形参
		gateway.openWireStream = async function openWireStream(endpoint, payload, uplink, peer, signal, control) {
			seen.wireStreamArgs.push({ endpoint, payload, uplink, peer, signal, control });
			return emitFrames(signal);
		};
	} else {
		// 0.1.x 真实签名：signal 是第 3 个形参
		gateway.openWireStream = async function openWireStream(endpoint, payload, signal) {
			seen.wireStreamArgs.push({ endpoint, payload, signal });
			return emitFrames(signal);
		};
	}

	// ── 私有成员：两代都提供，但插件必须能识别"缺失" ──
	const permissionPresets = {
		names: ["read-only", "accept-edits"],
		presets: { "accept-edits": { name: "Accept Edits", description: "接受编辑" } },
		apply() { return undefined; },
	};
	const workspaceRegistry = {
		archivedSessionIds: [],
		list: () => [{ id: "ws-1", path: "/tmp/proj", title: "proj", sessionIds: [] }],
		enqueueOperation: async (fn) => fn(),
		requireState: () => ({ archivedSessionIds: [] }),
		setState: async () => undefined,
	};

	provided.set("agents", { get: (id) => (id === "session-A" ? AGENT : undefined), list: () => [AGENT], roots: () => [AGENT] });
	provided.set("sessions", { get: (id) => (id === "session-A" ? { id: "session-A", header: { cwd: "/tmp/proj" } } : undefined), list: () => [{ id: "session-A", header: { cwd: "/tmp/proj" } }] });
	provided.set("jobs", jobs);
	provided.set("settings", settings);
	provided.set("typertGateway", gateway);
	provided.set("permissionPresets", permissionPresets);
	provided.set("workspaceRegistry", workspaceRegistry);
	provided.set("llm", {
		// 必须返回**至少一个带 settingsNs 的可配置提供商**，否则 /llm-providers 根本不会去读设置，
		// 设置读取的两条分支就都不会被执行到（这正是"夹具没驱动到分支"的陷阱）。
		listProviders: () => [],
		listConfigurableProviders: () => [{ provider: "deepseek-official", displayName: "DeepSeek", settingsNs: "providers", settingsPath: [] }],
		listModels: async () => [],
	});
	provided.set("approval", { setPolicy() {}, current: () => "accept-edits" });
	provided.set("credentials", { describe: () => [], resolve: () => undefined });
	provided.set("commands", { list: () => [] });

	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn: (m) => logs.warn.push(String(m)), info: (m) => logs.info.push(String(m)) },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on() { return () => {}; },
		effect(callback) {
			const disposer = callback?.();
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
		waterfall: async () => "unavailable",
	};
	const dispose = apply(ctx, CONFIG);
	const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		seen, logs, provided, wait,
		clean() { dispose?.(); },
	};
}

// ───────────────────── 1. 纯谓词（判别器本身） ─────────────────────

test("jobsNeedsSessionId：按事件流存在性判别任务服务的代际", () => {
	assert.equal(jobsNeedsSessionId({ events: { subscribe() {} } }), true);
	assert.equal(jobsNeedsSessionId({ onJobsChanged() {}, onJobDone() {} }), false);
	assert.equal(jobsNeedsSessionId(undefined), false);
});

test("jobsCallerFor：0.2.x 给 SessionId 字符串，0.1.x 给 Agent 对象", () => {
	const modern = { events: { subscribe() {} } };
	const legacy = { onJobsChanged() {} };
	assert.equal(jobsCallerFor(modern, AGENT, "session-A"), "session-A");
	assert.equal(jobsCallerFor(legacy, AGENT, "session-A"), AGENT);
	// caller 缺失时两代都传 undefined（不是 "undefined" 字符串）
	assert.equal(jobsCallerFor(modern, undefined, undefined), undefined);
	assert.equal(jobsCallerFor(legacy, undefined, undefined), undefined);
	// 有 agent 但没有显式 sessionId 时，从 agent 推出 id（并去掉 session: 前缀）
	assert.equal(jobsCallerFor(modern, { id: "session-B" }, undefined), "session-B");
	assert.equal(jobsCallerFor(modern, { id: "session:session-C" }, undefined), "session-C");
});

test("readSettingsSection：0.2.x 走 describe 取 value，0.1.x 走 get", () => {
	const legacy = { get: (ns) => ({ ns, from: "get" }) };
	assert.deepEqual(readSettingsSection(legacy, "providers"), { ns: "providers", from: "get" });

	const modern = { describe: () => [{ ns: "providers", value: { from: "describe" } }, { ns: "other", value: 1 }] };
	assert.deepEqual(readSettingsSection(modern, "providers"), { from: "describe" });
	// 描述符里没有该命名空间 → undefined（调用方按"无此配置"处理，不得抛错）
	assert.equal(readSettingsSection(modern, "absent"), undefined);
	// 宿主读设置时抛错 → 吞掉并返回 undefined，不拖垮调用方
	assert.equal(readSettingsSection({ get: () => { throw new Error("boom"); } }, "providers"), undefined);
	// 两代特征都没有 → undefined
	assert.equal(readSettingsSection({}, "providers"), undefined);
});

test("wireStreamTakesControl：按形参个数判别取消信号位次", () => {
	const legacy = { openWireStream: function (endpoint, payload, signal) {} };
	const modern = { openWireStream: function (endpoint, payload, uplink, peer, signal, control) {} };
	assert.equal(wireStreamTakesControl(legacy), false);
	assert.equal(wireStreamTakesControl(modern), true);
	assert.equal(wireStreamTakesControl({}), false);
});

test("capabilityState：三态（ok / drift / missing）", () => {
	assert.equal(capabilityState(undefined, () => true), "missing");
	assert.equal(capabilityState({ list() {} }, (s) => typeof s.list === "function"), "ok");
	assert.equal(capabilityState({}, (s) => typeof s.list === "function"), "drift");
	// 判定谓词自身抛错也归为 drift（形状不符预期）
	assert.equal(capabilityState({}, () => { throw new Error("x"); }), "drift");
});

// ───────────────────── 2. 0.2.x 宿主（本机真实代际） ─────────────────────

test("0.2.x：/jobs 传给宿主的是 SessionId 字符串（不是 Agent 对象）", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		const res = await call(h.route, { url: "/m/api/jobs?sessionId=session-A" });
		assert.equal(res.status, 200);
		assert.equal(h.seen.jobsList.length, 1);
		assert.equal(typeof h.seen.jobsList[0], "string", "0.2.x 必须传字符串，传对象会恒返回空");
		assert.equal(h.seen.jobsList[0], "session-A");
	} finally { h.clean(); }
});

test("0.2.x：/jobs/kill 传给宿主的是 SessionId 字符串", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		const res = await call(h.route, { url: "/m/api/jobs/kill", method: "POST", body: { jobId: "j-1", sessionId: "session-A" } });
		assert.equal(res.status, 200);
		assert.equal(h.seen.jobsKill.length, 1);
		assert.equal(typeof h.seen.jobsKill[0].caller, "string", "0.2.x 传对象会报'任务属于另一个会话'");
		assert.equal(h.seen.jobsKill[0].caller, "session-A");
	} finally { h.clean(); }
});

test("0.2.x：任务事件走统一的 events.subscribe，而不是已移除的两个旧回调", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		await h.wait(30);
		assert.equal(h.seen.eventsSubscribe.length, 1, "应恰好订阅一次（一个 {owners:'all'} 覆盖两种旧回调）");
		assert.deepEqual(h.seen.eventsSubscribe[0].filter, { owners: "all" });
		assert.equal(typeof h.seen.eventsSubscribe[0].listener, "function");
		assert.equal(h.seen.legacyJobCallbacks, 0);
	} finally { h.clean(); }
});

test("0.2.x：事件流的取消信号落在第 5 位（传错位会让通道永远不就绪）", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		await h.wait(30);
		assert.equal(h.seen.wireStreamArgs.length, 1);
		const args = h.seen.wireStreamArgs[0];
		assert.equal(args.endpoint, "$events");
		assert.ok(args.signal instanceof AbortSignal, "signal 必须真的传进去；为 undefined 时宿主会在 AbortSignal.any 抛错");
		assert.equal(args.uplink, undefined, "第 3 位必须是 uplink（0.2.x 语义），不能把信号塞在这里");
	} finally { h.clean(); }
});

test("0.2.x：设置读取走 describe()，不调用已移除的 get()", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		const res = await call(h.route, { url: "/m/api/llm-providers" });
		assert.equal(res.status, 200);
		assert.ok(h.seen.settingsDescribe > 0, "0.2.x 必须走 describe()");
		assert.equal(h.seen.settingsGet.length, 0, "0.2.x 没有 get()，不应调用");
	} finally { h.clean(); }
});

// ───────────────────── 3. 0.1.x 宿主（真实宿主验不到，靠夹具保护） ─────────────────────

test("0.1.x：/jobs 传给宿主的是 Agent 对象（旧代实现内部取其 .id）", async () => {
	const h = createHarness({ generation: "0.1.5" });
	try {
		const res = await call(h.route, { url: "/m/api/jobs?sessionId=session-A" });
		assert.equal(res.status, 200);
		assert.equal(h.seen.jobsList.length, 1);
		assert.equal(typeof h.seen.jobsList[0], "object", "0.1.x 必须传 Agent 对象；传字符串会被解析成 undefined");
		assert.equal(h.seen.jobsList[0]?.id, "session-A");
	} finally { h.clean(); }
});

test("0.1.x：任务事件仍走两个旧回调（新 API 不存在时不得静默不订阅）", async () => {
	const h = createHarness({ generation: "0.1.5" });
	try {
		await h.wait(30);
		assert.equal(h.seen.legacyJobCallbacks, 2, "onJobsChanged 与 onJobDone 都应被注册");
		assert.equal(h.seen.eventsSubscribe.length, 0);
	} finally { h.clean(); }
});

test("0.1.x：事件流的取消信号落在第 3 位", async () => {
	const h = createHarness({ generation: "0.1.5" });
	try {
		await h.wait(30);
		assert.equal(h.seen.wireStreamArgs.length, 1);
		assert.ok(h.seen.wireStreamArgs[0].signal instanceof AbortSignal, "0.1.x 的 signal 是第 3 个形参");
	} finally { h.clean(); }
});

test("0.1.x：设置读取走 get()", async () => {
	const h = createHarness({ generation: "0.1.5" });
	try {
		const res = await call(h.route, { url: "/m/api/llm-providers" });
		assert.equal(res.status, 200);
		assert.ok(h.seen.settingsGet.length > 0, "0.1.x 必须走 get()");
		assert.equal(h.seen.settingsDescribe, 0);
	} finally { h.clean(); }
});

// ───────────────────── 4. 诊断三态报告（ADR 0017 的硬要求） ─────────────────────

test("诊断：两代都报告宿主能力三态与实际代际选择", async () => {
	for (const generation of ["0.1.5", "0.2.0"]) {
		const h = createHarness({ generation });
		try {
			const res = await call(h.route, { url: "/m/api/diagnostics" });
			assert.equal(res.status, 200);
			const caps = res.body.checks?.hostCapabilities;
			assert.ok(caps && typeof caps === "object", `${generation} 应报告 hostCapabilities`);
			for (const key of ["jobs.callerShape", "jobs.eventsApi", "settings.read", "gateway.wireStream", "permissionPresets.apply", "workspaceRegistry.stateWrite"]) {
				assert.equal(caps[key], "ok", `${generation} 的 ${key} 应为 ok（两代都合法）`);
			}
			const gen = res.body.checks?.hostGeneration;
			assert.equal(gen.jobsCaller, generation === "0.2.0" ? "sessionId" : "agent");
			assert.equal(gen.settingsRead, generation === "0.2.0" ? "describe" : "get");
			assert.equal(gen.wireStreamArgs, generation === "0.2.0" ? "controlArg" : "legacyArg");
		} finally { h.clean(); }
	}
});

test("诊断：私有成员缺失时报 drift 并给出可执行原因（不静默）", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		// 模拟"服务在、但插件要用的私有成员没了"——这正是能力语义漂移的形态
		h.provided.set("permissionPresets", { names: ["read-only"] }); // 无 apply
		h.provided.set("workspaceRegistry", { list: () => [] }); // 无 enqueueOperation/requireState/setState
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		assert.equal(res.body.checks.hostCapabilities["permissionPresets.apply"], "drift");
		assert.equal(res.body.checks.hostCapabilities["workspaceRegistry.stateWrite"], "drift");
		const notes = res.body.notes ?? [];
		assert.ok(notes.some((n) => String(n).includes("宿主能力非全绿")), "降级必须出现在 notes 里，而不只是状态值");
	} finally { h.clean(); }
});

// ───────────────────── 5. apiProxy 死代码清除后的行为 ─────────────────────

test("/respond：待办不在本地清单时返回 404 并说明真实原因（不再归咎于'内核过旧'）", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		const res = await call(h.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { rpcId: "rpc-does-not-exist", kind: "approval", sessionId: "session-A", approvalId: "a-1", outcome: "allow" },
		});
		assert.equal(res.status, 404);
		assert.equal(res.body.error, "respond-not-pending");
		assert.ok(!String(res.body.detail ?? "").includes("apiProxy"), "错误原因不得再提已移除的 apiProxy");
	} finally { h.clean(); }
});

// ───────────────────── 6. 评审修复的回归测试 ─────────────────────

const QUESTION_REPLAY_FRAME = {
	type: "waterfall", event: "user-questions/request", eventId: "ev-q-replay", agentId: "session-A",
	request: { questions: [{ id: "q1", question: "Replayed?", options: [{ label: "Yes" }] }] },
};

test("同一问询被重复投递：仍只有一个待办与一份回放帧（评审 WARNING 2）", async () => {
	// 宿主在新连接建立时会重投尚未结算的事件（dsh-api-gateway 的 remoteEventClients 交付逻辑），
	// 因此**同一个 eventId 会被插件看到不止一次**。这里把同一帧在一次连接内投递两次来驱动该语义
	// ——对插件而言与"断开→重连→回放"等价（身份相同、内容相同），但不必让重连循环持续运行。
	const h = createHarness({ generation: "0.2.0", frames: [QUESTION_REPLAY_FRAME, QUESTION_REPLAY_FRAME] });
	try {
		const deadline = Date.now() + 10_000;
		while (h.seen.framesDelivered < 2 && Date.now() < deadline) await h.wait(20);
		assert.equal(h.seen.framesDelivered, 2, "同一帧应被投递两次");
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		// 身份不稳定时这两项会各变成 2（评审复现：pendingQuestions / pendingFrames 由 1 增至 2）
		assert.equal(res.body.checks.pendingQuestions, 1, "重复投递不得产生第二个待办");
		assert.equal(res.body.checks.pendingFrames, 1, "重复投递不得产生第二份待发送帧");
		// 用帧里的身份回答必须被接受（身份不稳定时旧实现会 400 interaction-mismatch）
		const answer = await call(h.route, {
			url: "/m/api/respond", method: "POST",
			body: { rpcId: "ev-q-replay", kind: "question", sessionId: "session-A", questionId: "session-A:ev-q-replay", answers: [{ id: "q1", selected: ["Yes"] }] },
		});
		assert.notEqual(answer.status, 400, "携带帧内身份的回答不得被判 mismatch");
	} finally { h.clean(); }
});

test("任务事件：output 不触发全量扫描，无连接时任何事件都不扫描（评审 WARNING 3）", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		await h.wait(30);
		const sub = h.seen.eventsSubscribe[0];
		assert.ok(sub, "0.2.x 应已订阅任务事件流");
		const before = h.seen.jobsList.length;
		sub.listener({ type: "output", job: { id: "j1", status: "running" } });
		assert.equal(h.seen.jobsList.length, before, "output 事件不得触发 jobs.list 全量扫描（投影不含输出内容）");
		// 零移动端连接时，扫描唯一的目的（广播）不存在，生命周期事件也应跳过
		sub.listener({ type: "progress", job: { id: "j1", status: "running" } });
		assert.equal(h.seen.jobsList.length, before, "无连接时即使生命周期事件也不应扫描");
	} finally { h.clean(); }
});

test("诊断：仅 presets 缺失时目录降级必须显式报出（评审 WARNING 5）", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		// 目录读取依赖的是私有 presets，与 names/apply 是不同成员：只缺 presets 时，
		// 目录会静默退化成「只有内置 read-only」，诊断必须看得见。
		h.provided.set("permissionPresets", { names: ["read-only"], apply() { return undefined; } });
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		assert.equal(res.body.checks.hostCapabilities["permissionPresets.catalog"], "drift", "缺 presets 必须报 drift");
		assert.equal(res.body.checks.hostCapabilities["permissionPresets.apply"], "ok", "names/apply 仍在，不应误报");
		assert.ok((res.body.notes ?? []).some((n) => String(n).includes("宿主能力非全绿")), "降级必须写入 notes");
		// 同时确认目录端点确实降级（而不是抛错）——与诊断口径一致
		const catalog = await call(h.route, { url: "/m/api/catalog" });
		assert.equal(catalog.status, 200);
	} finally { h.clean(); }
});

test("曾就绪的通道在断开后持续重连，且退避等待不泄漏监听器（评审 BLOCKING 1 + WARNING 4）", async (t) => {
	// 用 mock timers 推进退避：真实等待序列是 3s/6s/12s/…，不模拟则无法在合理时间内
	// 观察到「越过有界重试上限之后仍在重连」。这条正是 BLOCKING 的判别点：
	// 旧实现用「每轮开始前的就绪快照」判断，首轮就绪后断流会被误判为「从未就绪」，
	// 耗尽 READY_RETRY_MAX（6）后退出——总计 7 次打开即永久停止。
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const h = createHarness({ generation: "0.2.0", frames: [], endAfterFrames: true });
	try {
		for (let i = 0; i < 12; i += 1) {
			t.mock.timers.tick(60_000);
			await new Promise((resolve) => setImmediate(resolve));
		}
		const opens = h.seen.wireStreamArgs.length;
		const signal = h.seen.wireStreamArgs[0]?.signal;
		// 必须在**恢复真实定时器之前**卸载：否则在途的（被 mock 的）退避定时器永远不会触发，
		// 插件里那个 async IIFE 会留下一个永不 settle 的 promise，测试文件随即挂住。
		h.clean();
		t.mock.timers.reset();
		await new Promise((resolve) => setImmediate(resolve));
		assert.ok(signal instanceof AbortSignal, "夹具应收到取消信号");
		assert.ok(opens > 7, `曾就绪后应持续重连（越过有界上限 6），实际打开 ${opens} 次`);
		// WARNING 4 的判据是「不累积」而非「为零」：卸载时若恰有一个在途等待，它会经 abort
		// 路径被清理；真有泄漏（每次等待都留下监听器）时这里会是十几次。
		const listeners = getEventListeners(signal, "abort").length;
		assert.ok(listeners <= 1, `已完成的退避等待不得累积 abort 监听器，实际残留 ${listeners} 个`);
	} finally {
		h.clean();
		t.mock.timers.reset();
	}
});
