/**
 * 宿主代际兼容回归测试（issue #34 / DSH 0.2.1-rc.2）。
 *
 * 为什么需要**新的**两代夹具：0.2.1 的破坏点不在"服务或成员缺失"，而在**实参语义收紧**——
 * 网关的四个入口（`invokeRpc` / `stream` / `openWireStream` / `dispatchRpc`）从"peer 可省、
 * 网关用 operator Peer 兜底"变成"peer 必填、`assertPeerLive` 先解引用 `peer.signal`"。
 * 传错/漏传不报参数错误，只会在宿主内部抛 TypeError 并被插件的重试/错误映射吞掉——
 * 症状是 RPC 全挂 + `approvalMode=both` 静默降级。既有夹具只表达"服务在不在"，测不出来。
 *
 * 关键约束（与本文件全部断言对应）：
 * 1. 0.2.1 上插件必须把 `connection.createPeer` 造出的**活** Peer 传到**正确实参位次**：
 *    `invokeRpc(endpoint, payload, signal, peer)`、`stream({..., peer})`、
 *    `openWireStream(endpoint, payload, uplink, peer, signal, ...)`、`dispatchRpc(endpoint, payload, signal, peer)`；
 * 2. 开流与该流的 `$events/result` 结算必须是**同一个 Peer 实例**（宿主按 `client.peer !== peer` 匹配）；
 * 3. 0.2.0 / 0.1.x 不得被误改：仍传 undefined / 走旧实参位次；
 * 4. 取不到 peer 时必须**显式报 drift**（`gateway.eventsPeer` + 原因码），不静默伪装成功。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply, hostPeerSource, createInProcessPeer } from "../lib/index.js";

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

/** 进程内 Peer 的假实现：形状对齐 0.2.1 的 PeerScope（signal / principal / interactions / dispose）。 */
let peerSeq = 0;
function makePeer(options) {
	const lifetime = new AbortController();
	return {
		id: `peer-${++peerSeq}`,
		principal: options.principal,
		interactions: options.interactions ?? "answer",
		signal: lifetime.signal,
		disposed: false,
		dispose() {
			if (this.disposed) return Promise.resolve();
			this.disposed = true;
			lifetime.abort(new Error(`Peer ${this.id} was disposed`));
			return Promise.resolve();
		},
	};
}

/**
 * 两代宿主夹具：
 * - `0.2.1`：网关四入口要求活 Peer（principal=owner、interactions=answer），
 *            进程内 Peer 来源是 `connection.createPeer`；`openWireStream` 形参 7 个；
 * - `0.2.0`：peer 可省（网关自带 `operatorPeer` 兜底）、`openWireStream` 形参 6 个；
 * - `0.1.5`：`openWireStream` 形参 3 个（signal 在第 3 位），jobs/settings 走旧接口。
 *
 * `withConnection: false` 用来复现"网关入口都在、但 peer 来源缺失"的漂移形态（issue #34 诊断项）。
 */
function createHarness({ generation, withConnection = true, frames = [] } = {}) {
	const routes = [];
	const provided = new Map();
	const logs = { warn: [], info: [] };
	const seen = {
		wire: null,
		wireSignal: null,
		invokePeer: null,
		invokeCalls: [],
		streamRequest: null,
		dispatchPeer: null,
		dispatchCalls: [],
		createPeerCalls: [],
		peers: [],
	};
	// 宿主侧的"当前 $events 流的 peer"——dispatchRpc 用它复刻 `client.peer !== peer` 校验
	let streamPeer = null;
	const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
	/** 轮询等待条件成立（比固定 sleep 稳；predicate 可为 async）。 */
	const until = async (predicate, timeoutMs = 3000, stepMs = 15) => {
		const deadline = Date.now() + timeoutMs;
		for (;;) {
			if (await predicate()) return true;
			if (Date.now() >= deadline) return false;
			await wait(stepMs);
		}
	};

	// 0.2.1 才有 connection.createPeer；旧代真实宿主没有，夹具不得凭空提供
	const connection = generation === "0.2.1" && withConnection
		? {
			createPeer(options) {
				seen.createPeerCalls.push(options);
				const peer = makePeer(options);
				seen.peers.push(peer);
				return peer;
			},
		}
		: undefined;

	/** 复刻 0.2.1 网关的 peer 校验：每条错误分支都与宿主真实抛出的语义一致。 */
	const livePeerError = (peer) => {
		if (peer === undefined || peer === null) return new TypeError("Cannot read properties of undefined (reading 'signal')");
		if (peer.signal?.aborted) return Error("gateway/peer-disposed: the calling Peer has been disposed");
		if (peer.interactions !== "answer") return Error("gateway/interactions-forbidden: forwarded Remote events require interactions=answer");
		if (peer.principal?.kind !== "owner") return Error("gateway/invocation-unavailable: only owner Peers answer forwarded Remote events");
		return null;
	};

	const holdOpenUntilAborted = (signal) => new Promise((resolve) => {
		if (!signal || signal.aborted) return resolve();
		signal.addEventListener("abort", () => resolve(), { once: true });
	});
	const emitFrames = async function* (signal) {
		yield { type: "ready", clientId: "client-1" };
		for (const frame of frames) yield frame;
		await holdOpenUntilAborted(signal);
	};

	const gateway = {};
	if (generation === "0.2.1") {
		// 真实签名 7 个形参（0.2.1 在末尾新增 uplinkWindow），`.length >= 5` 仍判 controlArg 分支
		gateway.openWireStream = async function openWireStream(endpoint, payload, uplink, peer, signal, control, uplinkWindow) {
			seen.wire = { endpoint, payload, uplink, peer, signal, control, uplinkWindow };
			seen.wireSignal = signal;
			streamPeer = peer ?? null;
			const err = livePeerError(peer);
			if (err) throw err; // 与宿主一致：$events 分支先 assertPeerLive 再开流
			return emitFrames(signal);
		};
		gateway.invokeRpc = async (endpoint, payload, signal, peer) => {
			seen.invokeCalls.push({ endpoint, payload });
			seen.invokePeer = peer;
			const err = livePeerError(peer);
			if (err) return { ok: false, error: { code: "gateway/internal", message: err.message } };
			return { ok: true, value: {} };
		};
		gateway.stream = async (request) => {
			seen.streamRequest = request;
			const err = livePeerError(request.peer);
			if (err) throw err;
			return (async function* () { yield { type: "baseline", value: { projections: {} } }; })();
		};
		gateway.dispatchRpc = async (endpoint, payload, signal, peer) => {
			seen.dispatchCalls.push({ endpoint, payload });
			seen.dispatchPeer = peer;
			const err = livePeerError(peer);
			if (err) return { ok: false, error: { code: "gateway/internal", message: err.message } };
			// 宿主：Remote event result belongs to another Peer
			if (endpoint === "$events/result" && streamPeer !== null && peer !== streamPeer) {
				return { ok: false, error: { code: "gateway/interactions-forbidden", message: "Remote event result belongs to another Peer" } };
			}
			return { ok: true, value: undefined };
		};
	} else if (generation === "0.2.0") {
		// 0.2.0：网关自带 operator Peer 兜底，peer 形参可省；openWireStream 形参 6 个
		gateway.operatorPeer = () => makePeer({ principal: { kind: "owner" }, interactions: "answer" });
		gateway.openWireStream = async function openWireStream(endpoint, payload, uplink, peer, signal, control) {
			seen.wire = { endpoint, payload, uplink, peer, signal, control };
			seen.wireSignal = signal;
			return emitFrames(signal);
		};
		gateway.invokeRpc = async (endpoint, payload, signal, peer) => {
			seen.invokeCalls.push({ endpoint, payload });
			seen.invokePeer = peer;
			return { ok: true, value: {} };
		};
		gateway.dispatchRpc = async (endpoint, payload, signal, peer) => {
			seen.dispatchCalls.push({ endpoint, payload });
			seen.dispatchPeer = peer;
			return { ok: true, value: undefined };
		};
	} else {
		// 0.1.5：openWireStream 形参 3 个，signal 在第 3 位；两代都不该传 peer
		gateway.openWireStream = async function openWireStream(endpoint, payload, signal) {
			seen.wire = { endpoint, payload, signal };
			seen.wireSignal = signal;
			return emitFrames(signal);
		};
		gateway.invokeRpc = async (endpoint, payload) => {
			seen.invokeCalls.push({ endpoint, payload });
			return { ok: true, value: {} };
		};
	}

	// ── 插件启动所需的内核服务（与 host-compat-020 夹具同源，仅保留 apply 真正触达的）──
	const agent = { id: "session-A", session: { id: "session-A", header: { cwd: "/tmp/proj" } }, status: "idle" };
	const jobs = {
		list: () => [],
		kill: () => "requested",
	};
	if (generation === "0.1.5") {
		jobs.onJobsChanged = () => () => {};
		jobs.onJobDone = () => () => {};
	} else {
		jobs.events = { subscribe: () => () => {} };
	}
	const settings = generation === "0.1.5"
		? { get: () => ({}) }
		: { describe: () => [{ ns: "providers", value: {} }] };
	provided.set("agents", { get: (id) => (id === "session-A" ? agent : undefined), list: () => [agent], roots: () => [agent] });
	provided.set("sessions", {
		get: (id) => (id === "session-A" ? { id: "session-A", header: { id: "session-A", cwd: "/tmp/proj", createdAt: 1 } } : undefined),
		list: () => [{ id: "session-A", header: { id: "session-A", cwd: "/tmp/proj", createdAt: 1 } }],
	});
	provided.set("jobs", jobs);
	provided.set("settings", settings);
	provided.set("typertGateway", gateway);
	if (connection !== undefined) provided.set("connection", connection);
	provided.set("permissionPresets", {
		names: ["read-only", "workspace-write", "danger-full-access"],
		presets: { "workspace-write": { name: "Workspace Write", description: "写工作区" } },
		apply: () => undefined,
	});
	provided.set("workspaceRegistry", {
		list: () => [{ id: "ws-1", path: "/tmp/proj", title: "proj", sessionIds: [] }],
		enqueueOperation: async (fn) => fn(),
		requireState: () => ({ archivedSessionIds: [] }),
		setState: async () => undefined,
	});
	provided.set("llm", {
		listProviders: () => [],
		listConfigurableProviders: () => [],
		listModels: async () => [],
	});
	provided.set("approval", { setPolicy() {}, current: () => "workspace-write" });
	provided.set("credentials", { describe: () => [], resolve: () => undefined });
	provided.set("commands", { list: () => [] });

	const effectDisposers = [];
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43121, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn: (m) => logs.warn.push(String(m)), info: (m) => logs.info.push(String(m)) },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on() { return () => {}; },
		effect(callback) {
			const disposer = callback?.();
			if (typeof disposer === "function") effectDisposers.push(disposer);
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
		waterfall: async () => "unavailable",
	};
	const dispose = apply(ctx, CONFIG);
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		seen, logs, provided, wait, until,
		clean() {
			// 模拟 Cordis 卸载：先跑 effect 清理（Peer dispose 等），再调 apply 的返回值
			for (const disposer of effectDisposers.splice(0)) {
				try { disposer(); } catch { /* 卸载期忽略 */ }
			}
			dispose?.();
		},
	};
}

// ───────────────────── 1. 纯判别器 ─────────────────────

test("hostPeerSource：按结构特征判别进程内 Peer 来源（不按版本号）", () => {
	assert.equal(hostPeerSource(undefined, { createPeer() {} }), "createPeer");
	assert.equal(hostPeerSource({ operatorPeer() {} }, undefined), "operatorPeer");
	assert.equal(hostPeerSource({ operatorPeer() {} }, { createPeer() {} }), "createPeer", "0.2.1 同时有两条时优先 createPeer");
	assert.equal(hostPeerSource({}, {}), "none");
	assert.equal(hostPeerSource(undefined, undefined), "none");
});

test("createInProcessPeer：只认 createPeer；旧代返回 undefined（让网关兜底）", () => {
	assert.equal(createInProcessPeer(undefined), undefined);
	assert.equal(createInProcessPeer({}), undefined);
	let received;
	const peer = { id: "p" };
	const made = createInProcessPeer({ createPeer(options) { received = options; return peer; } });
	assert.equal(made, peer);
	// 主体必须是 owner（与 0.2.0 的 operator Peer 同语义）；interactions=answer 才能开 $events
	assert.deepEqual(received, { principal: { kind: "owner" }, interactions: "answer" });
});

// ───────────────────── 2. 0.2.1（本次适配目标） ─────────────────────

test("0.2.1：$events 开流收到 connection.createPeer 造的活 Peer（第 4 实参）", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		assert.ok(await h.until(() => h.seen.wire !== null), "approvalMode=both 应尝试开 $events 流");
		assert.equal(h.seen.wire.endpoint, "$events");
		assert.ok(h.seen.wire.uplink?.[Symbol.asyncIterator], "第 3 位必须是 uplink（异步迭代器；宿主可能对它调用 return()）");
		const peer = h.seen.wire.peer;
		assert.ok(peer, "0.2.1 上第 4 位 peer 必填：漏传会让宿主 assertPeerLive 抛 TypeError");
		assert.equal(peer.principal?.kind, "owner");
		assert.equal(peer.interactions, "answer");
		assert.ok(peer.signal instanceof AbortSignal);
		assert.ok(h.seen.wireSignal instanceof AbortSignal, "取消信号仍须落在第 5 位");
		assert.equal(h.seen.createPeerCalls.length, 1, "Peer 是插件级单例，不应每次开流新建");
	} finally { h.clean(); }
});

test("0.2.1：$events 就绪后 remoteEvents=true（双端审批通道真的可用）", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		assert.ok(await h.until(() => h.seen.wire !== null && h.seen.wire.peer !== undefined));
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		assert.equal(res.body.checks.remoteEvents, true);
		assert.equal(res.body.checks.hostGeneration.wireStreamArgs, "controlArg");
	} finally { h.clean(); }
});

test("0.2.1：RPC 调用带同一个 Peer，且与 $events 开流同源（结算身份匹配的前提）", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		assert.ok(await h.until(() => h.seen.wire !== null));
		const res = await call(h.route, { url: "/m/api/defaults", method: "POST", body: { permissionPreset: "workspace-write" } });
		assert.equal(res.status, 200, `0.2.1 上 default 写入应成功，实际：${JSON.stringify(res.body)}`);
		assert.equal(h.seen.invokeCalls.length, 1);
		assert.equal(h.seen.invokeCalls[0].endpoint, "settings/update");
		assert.ok(h.seen.invokePeer, "invokeRpc 第 4 实参必须是活 Peer");
		assert.equal(h.seen.invokePeer, h.seen.wire.peer, "开流与结算必须是同一个 Peer 实例（宿主按 client.peer 匹配）");
		assert.equal(h.seen.createPeerCalls.length, 1, "跨调用复用同一 Peer，不累积");
	} finally { h.clean(); }
});

test("0.2.1：基线流 stream() 的 request.peer 也必须是同一个 Peer", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		assert.ok(await h.until(() => h.seen.wire !== null));
		const res = await call(h.route, { url: "/m/api/session-config?sessionId=session-A" });
		assert.equal(res.status, 200, `session-config 应成功，实际：${JSON.stringify(res.body)}`);
		assert.ok(h.seen.streamRequest, "session.control 走 stream 基线流");
		assert.ok(h.seen.streamRequest.peer, "request.peer 必填：漏传会被宿主 assertPeerLive 拒绝（readSessionConfig 吞错，200 也看不见）");
		assert.equal(h.seen.streamRequest.peer, h.seen.wire.peer);
	} finally { h.clean(); }
});

test("0.2.1：诊断把 peer 来源显式报出（gateway.eventsPeer=ok / hostGeneration.eventsPeer=createPeer）", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		const caps = res.body.checks.hostCapabilities;
		for (const key of [
			"jobs.callerShape", "jobs.eventsApi", "settings.read", "gateway.wireStream",
			"gateway.eventsPeer", "permissionPresets.apply", "permissionPresets.catalog", "workspaceRegistry.stateWrite",
		]) {
			assert.equal(caps[key], "ok", `0.2.1 上 ${key} 应为 ok`);
		}
		assert.equal(res.body.checks.hostGeneration.eventsPeer, "createPeer");
		assert.equal(res.body.checks.hostCapabilityReasons, undefined, "全绿时不应带原因码");
	} finally { h.clean(); }
});

test("0.2.1：取不到 peer 来源时显式报 drift（不再把必失败报成绿灯）", async () => {
	const h = createHarness({ generation: "0.2.1", withConnection: false });
	try {
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		assert.equal(res.body.checks.hostCapabilities["gateway.wireStream"], "ok", "旧判据只看到方法在");
		assert.equal(res.body.checks.hostCapabilities["gateway.eventsPeer"], "drift", "新判据必须指出 peer 来源缺失");
		assert.equal(res.body.checks.hostCapabilityReasons["gateway.eventsPeer"], "gateway-peer-source-missing");
		assert.equal(res.body.checks.hostGeneration.eventsPeer, "none");
		const notes = res.body.notes ?? [];
		assert.ok(notes.some((n) => String(n).includes("gateway.eventsPeer=drift")), "降级必须出现在 notes 里");
		// 同一环境下的真实调用应当失败并给出稳定错误码，而不是静默 200
		const write = await call(h.route, { url: "/m/api/defaults", method: "POST", body: { permissionPreset: "workspace-write" } });
		assert.equal(write.status, 400);
		assert.equal(write.body.error, "gateway/internal");
	} finally { h.clean(); }
});

test("0.2.1：$events/result 结算必须走通，且用开流那一个 Peer（宿主按 client.peer 匹配）", async () => {
	const h = createHarness({
		generation: "0.2.1",
		frames: [{
			type: "waterfall",
			eventId: "evt-1",
			event: "approval/request",
			agentId: "session-A",
			request: { callId: "call-1", toolName: "Bash", reason: "run tests" },
		}],
	});
	try {
		// 等到网关把 waterfall 转成待办（诊断的 pendingApprovals 即该条目）
		assert.ok(await h.until(async () => {
			const probe = await call(h.route, { url: "/m/api/diagnostics" });
			return (probe.body.checks?.pendingApprovals ?? 0) > 0;
		}), "waterfall 帧应生成待办条目");
		const res = await call(h.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "approval", approvalId: "session-A:call-1", rpcId: "evt-1", sessionId: "session-A", outcome: "allowed-once" },
		});
		assert.equal(res.status, 200);
		assert.equal(h.seen.dispatchCalls.length, 1, "结算必须走 $events/result，且只走一次");
		assert.equal(h.seen.dispatchCalls[0].endpoint, "$events/result");
		assert.equal(h.seen.dispatchCalls[0].payload.args.clientId, "client-1");
		assert.equal(h.seen.dispatchCalls[0].payload.args.outcome.kind, "result");
		assert.ok(h.seen.dispatchPeer, "dispatchRpc 第 4 实参必须是活 Peer");
		assert.equal(h.seen.dispatchPeer, h.seen.wire.peer, "结算与开流必须同一个 Peer 实例（否则宿主以 client.peer !== peer 拒绝）");
	} finally { h.clean(); }
});

// ───────────────────── 3. 0.2.0（回归：不得被本次适配改坏） ─────────────────────

test("0.2.0：仍不传 peer（网关自带 operatorPeer 兜底），并如实报告该代际", async () => {
	const h = createHarness({ generation: "0.2.0" });
	try {
		assert.ok(await h.until(() => h.seen.wire !== null), "0.2.0 也应开 $events 流");
		assert.equal(h.seen.wire.peer, undefined, "0.2.0 没有 createPeer，必须保持旧行为（传 undefined）");
		assert.ok(h.seen.wireSignal instanceof AbortSignal);
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		assert.equal(res.body.checks.hostCapabilities["gateway.eventsPeer"], "ok");
		assert.equal(res.body.checks.hostGeneration.eventsPeer, "operatorPeer");
		const write = await call(h.route, { url: "/m/api/defaults", method: "POST", body: { permissionPreset: "workspace-write" } });
		assert.equal(write.status, 200);
		assert.equal(h.seen.invokePeer, undefined, "0.2.0 的 invokeRpc 不需要 peer");
	} finally { h.clean(); }
});

// ───────────────────── 4. 0.1.x（legacy 路径保护） ─────────────────────

test("0.1.5：仍走 3 参 openWireStream，不引入 peer 语义", async () => {
	const h = createHarness({ generation: "0.1.5" });
	try {
		assert.ok(await h.until(() => h.seen.wire !== null), "0.1.5 也应开 $events 流");
		assert.ok(h.seen.wire.signal instanceof AbortSignal, "signal 是第 3 个形参");
		assert.equal(h.seen.wire.peer, undefined);
		const res = await call(h.route, { url: "/m/api/diagnostics" });
		assert.equal(res.status, 200);
		assert.equal(res.body.checks.hostCapabilities["gateway.eventsPeer"], "ok");
		assert.equal(res.body.checks.hostGeneration.eventsPeer, "legacy");
	} finally { h.clean(); }
});

// ───────────────────── 5. Peer 生命周期 ─────────────────────

test("0.2.1：缓存的 Peer 被外部 dispose（connection 服务重启）后自动重建，不永久失效", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		assert.ok(await h.until(() => h.seen.peers.length === 1));
		const first = h.seen.peers[0];
		assert.ok(first, "首次调用应已创建 Peer");
		await first.dispose(); // 模拟 connection 作用域销毁：Peer 的 signal 被 abort
		assert.equal(first.signal.aborted, true);
		const res = await call(h.route, { url: "/m/api/defaults", method: "POST", body: { permissionPreset: "workspace-write" } });
		assert.equal(res.status, 200, "aborted 缓存必须被识别并重建，否则会永久 gateway/peer-disposed");
		assert.equal(h.seen.createPeerCalls.length, 2);
		assert.notEqual(h.seen.invokePeer, first);
		assert.equal(h.seen.invokePeer.signal.aborted, false);
	} finally { h.clean(); }
});

test("插件卸载时释放进程内 Peer（不随重连/重载累积）", async () => {
	const h = createHarness({ generation: "0.2.1" });
	try {
		assert.ok(await h.until(() => h.seen.peers.length === 1));
		const peer = h.seen.peers[0];
		assert.equal(peer.disposed, false);
		h.clean();
		assert.equal(peer.disposed, true, "dispose 必须被调用，否则 Peer scope 泄漏");
	} finally { h.clean(); }
});
