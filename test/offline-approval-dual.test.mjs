/**
 * 离线审批接管 / 双端竞速 / 网关代际判定 的回归测试。
 *
 * 对应三个修复：
 *  1. 手机离线时不再把审批 `next()` 给一个不在场的桌面 —— 改为本地接管 + 超时 fail-close；
 *  2. 手机离线时**同时**放行桌面（`next()` 与 hold 竞速，先答者生效），回答"在家怎么办"；
 *  3. typertGateway 在 0.2.x 是位置参数 `(endpoint, payload, signal, peer)`，按 arity 判代际。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply } from "../lib/index.js";

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
	offlineHoldMs: 300_000,
	offlineAlsoDesktop: true,
};

class FakeRequest extends EventEmitter {
	constructor(url, method = "GET", headers = {}) {
		super();
		this.url = url;
		this.method = method;
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken, "content-type": "application/json", ...headers };
		this.socket = { remoteAddress: "127.0.0.1" };
		this.complete = true;
	}
}

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

/** 假宿主 ctx：捕获 `on()` 注册的处理器，模拟 0.2.x 的四参 gateway。 */
function createHarness(overrides = {}) {
	const routes = [];
	const provided = new Map();
	const handlers = new Map();
	const logs = { info: [], warn: [] };
	const rpcCalls = [];
	let dispose;

	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { info: (m) => logs.info.push(String(m)), warn: (m) => logs.warn.push(String(m)) },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on(event, handler) {
			if (!handlers.has(event)) handlers.set(event, []);
			handlers.get(event).push(handler);
			return () => {};
		},
		effect(callback) { callback?.(); return () => {}; },
		inject() {},
		waterfall: async () => "unavailable",
	};

	// 0.2.x 形态：四个形参，必须与 `gateway.invokeRpc.length >= 3` 的判据一致
	provided.set("typertGateway", {
		async invokeRpc(endpoint, payload, signal, peer) {
			rpcCalls.push({ endpoint, args: payload?.args, hasPeer: Boolean(peer?.principal), signal: Boolean(signal) });
			return { ok: true, value: {} };
		},
		async dispatchRpc() { return { ok: true, value: undefined }; },
		async openWireStream() {
			throw new Error("$events 在 0.2.x 上不可用（本夹具模拟降级路径）");
		},
	});

	if (overrides.services) for (const [k, v] of Object.entries(overrides.services)) provided.set(k, v);
	// 0.2.1 的进程内 Peer 来源：插件的网关调用必须携带它造的活 Peer。
	// （0.2.0 没有 createPeer 时插件应传 undefined，由网关 operatorPeer 兜底。）
	if (!overrides.services || !("connection" in overrides.services)) {
		provided.set("connection", {
			createPeer() {
				return {
					signal: new AbortController().signal,
					principal: { kind: "owner" },
					interactions: "answer",
					dispose() {},
				};
			},
		});
	}
	dispose = apply(ctx, { ...CONFIG, ...(overrides.config ?? {}) });

	return {
		route: (path) => routes.find((r) => r.path === path)?.handler,
		approval: () => handlers.get("approval/request")?.[0],
		logs,
		rpcCalls,
		clean() { dispose?.(); },
	};
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

const diagnostics = async (harness) => (await call(harness.route("/m/api"), { url: "/m/api/diagnostics" })).body;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const approvalRequest = (sessionId = "session-A") => ({
	agent: { session: { id: sessionId } },
	toolName: "write",
	callId: "call-1",
	reason: "needs approval",
});

/** 手机端应答（与 App 相同的那条 HTTP 通路）。 */
const respond = (harness, sessionId, rpcId, outcome) =>
	call(harness.route("/m/api"), {
		url: "/m/api/respond",
		method: "POST",
		body: { sessionId, kind: "approval", rpcId, outcome },
	});

// ───────── 1. 离线：接管而非放行 ─────────

test("离线审批：没有手机连接时也建条目（旧行为是立刻 next() 交桌面）", async () => {
	const harness = createHarness();
	try {
		const handler = harness.approval();
		assert.equal(typeof handler, "function", "approval/request 必须注册处理器");

		let nextCalled = 0;
		const pending = handler(approvalRequest(), async () => { nextCalled += 1; return new Promise(() => {}); });

		// 离线 + offlineAlsoDesktop 默认 true：桌面也会拿到卡，但手机侧必须同时记账
		await sleep(20);
		const diag = await diagnostics(harness);
		assert.equal(diag.checks.pendingApprovals, 1, "离线时也必须建立待答条目");
		assert.equal(diag.checks.pendingFrames, 1, "离线时必须写回放帧，供重连补发");
		assert.equal(nextCalled, 1, "桌面兜底仍应被放行（双端呈现）");

		// 手机应答后：拿到的就是手机的值，条目清空
		const answered = await respond(harness, "session-A", "session-A:call-1", "allowed-once");
		assert.equal(answered.status, 200, "手机应答应被接受");
		assert.equal(await pending, "allowed-once");
		assert.equal((await diagnostics(harness)).checks.pendingApprovals, 0);
	} finally {
		harness.clean();
	}
});

// ───────── 2. 离线 + 关掉桌面兜底：独占 ─────────

test("离线审批：mobile 模式下 with offlineAlsoDesktop=false 时独占，不惊动桌面", async () => {
	const harness = createHarness({ config: { approvalMode: "mobile", offlineAlsoDesktop: false } });
	try {
		let nextCalled = 0;
		const pending = harness.approval()(approvalRequest(), async () => { nextCalled += 1; return "rejected"; });

		await sleep(20);
		assert.equal(nextCalled, 0, "独占模式下不得调用 next()（否则桌面会弹卡）");
		assert.equal((await diagnostics(harness)).checks.pendingApprovals, 1);

		const answered = await respond(harness, "session-A", "session-A:call-1", "rejected");
		assert.equal(answered.status, 200, `手机应答应被接受：${JSON.stringify(answered.body)}`);
		assert.equal(await pending, "rejected");
	} finally {
		harness.clean();
	}
});

// ───────── 3. 双端竞速：桌面先答 → 手机侧收卡 ─────────

test("双端竞速：桌面先答时手机侧条目被收掉，不残留可点的幽灵卡", async () => {
	const harness = createHarness();
	try {
		let nextCalled = 0;
		const pending = harness.approval()(approvalRequest(), async () => {
			nextCalled += 1;
			await sleep(60);
			return "allowed-once"; // 桌面点了"允许一次"
		});

		// 桌面还没答复时，手机侧必须已经建好条目（否则"桌面先答后清卡"无从谈起）
		await sleep(20);
		assert.equal((await diagnostics(harness)).checks.pendingApprovals, 1, "桌面未答复期间手机侧条目应存在");

		assert.equal(await pending, "allowed-once", "竞速应返回桌面的答复");
		assert.equal(nextCalled, 1);
		await sleep(30); // 等 finishApproval 的清理由微任务落地
		const diag = await diagnostics(harness);
		assert.equal(diag.checks.pendingApprovals, 0, "桌面先答后手机侧条目必须清空");
		assert.equal(diag.checks.pendingFrames, 0, "回放帧必须同步清理，避免重连后幽灵卡");
	} finally {
		harness.clean();
	}
});

// ───────── 4. 超时 fail-close：内核不会悬挂 ─────────

test("离线超时：到点返回 unavailable，不把内核永远挂住", async () => {
	const harness = createHarness({ config: { offlineHoldMs: 80, offlineAlsoDesktop: false } });
	try {
		const started = Date.now();
		const outcome = await harness.approval()(approvalRequest(), async () => new Promise(() => {}));
		const elapsed = Date.now() - started;

		assert.equal(outcome, "unavailable");
		assert.ok(elapsed >= 60, `应按 offlineHoldMs 超时（实际 ${elapsed}ms）`);
		assert.equal((await diagnostics(harness)).checks.pendingApprovals, 0, "超时后条目必须清空");
	} finally {
		harness.clean();
	}
});

// ───────── 5. 网关代际：0.2.x 位置参数形态 ─────────
test("网关代际：0.2.x 四参 invokeRpc 走位置参数并携带 owner Peer", async () => {
	const harness = createHarness();
	try {
		const res = await call(harness.route("/m/api"), {
			url: "/m/api/sessions/stop",
			method: "POST",
			body: { sessionId: "session-A" },
		});
		assert.equal(res.status, 200, "位置参数形态下 /sessions/stop 不应再报 reading 'signal'");
		const call0 = harness.rpcCalls.find((c) => c.endpoint === "session/cancel");
		assert.ok(call0, "应调用 session/cancel");
		assert.deepEqual(call0.args, { request: { sessionId: "session-A" } });
		assert.equal(call0.hasPeer, true, "0.2.x 必须携带 Peer 身份");
		assert.equal(call0.signal, true, "0.2.x 必须把 signal 放在第三个实参");
	} finally {
		harness.clean();
	}
});

// ───────── 6. both 模式：手机在线时桌面同样弹卡 ─────────

test("双端同显：approvalMode=both 且手机在线时，桌面仍应收到审批（先答生效）", async () => {
	const harness = createHarness();
	try {
		// 打开一条 SSE 连接 = 手机在线（diagnostics 的 mobileOnline 依赖 connections.size）
		const res = new FakeResponse();
		harness.route("/m/api")(new FakeRequest("/m/api/events"), res);
		assert.equal((await diagnostics(harness)).runtime.metrics.mobileOnline, 1, "SSE 连接后应视为手机在线");

		let nextCalled = 0;
		const pending = harness.approval()(approvalRequest(), async () => {
			nextCalled += 1;
			await sleep(30);
			return "allowed-once"; // 桌面点了"允许一次"
		});

		assert.equal(await pending, "allowed-once", "手机在线时桌面答复也必须生效");
		assert.equal(nextCalled, 1, "both 模式下桌面必须收到卡（这正是 issue #9 的语义）");
		await sleep(30);
		assert.equal((await diagnostics(harness)).checks.pendingApprovals, 0, "桌面先答后手机侧条目应清空");
		res.destroy();
	} finally {
		harness.clean();
	}
});
