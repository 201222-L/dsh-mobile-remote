// issue #17：子代理列表端点契约回归。
//
// 覆盖外部可观察行为：
//  1. 活跃父会话分支：条目带 `createdAt`，且按 createdAt **降序**输出
//     （目录/内核列表是升序，插件必须显式反转——否则与休眠分支顺序相反）；
//  2. 休眠/归档父会话分支：同样带 `createdAt` 且按同一规则降序，与活跃分支一致；
//  3. 缺 createdAt 的条目排在最后，等值时按 id 升序稳定；
//  4. `status` 取自**活 agent** 的 AgentStatus（`idle`/`running`，映射为
//     `running`/`inactive`）：目录条目本身不带状态，issue #21 后不再透传
//     `subagents/list` 的 activity/diagnostic reason（该 RPC 在宿主 0.2.0 已删除）。
//
// 伪宿主 harness 沿用 test/interaction-settlement.test.mjs 的形态。
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

let apply;
let testHome;

test.before(async () => {
	testHome = await mkdtemp(join(tmpdir(), "dsh-mobile-subagent-order-"));
	process.env.HOME = testHome;
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
};

class FakeRequest extends EventEmitter {
	constructor(url, method = "GET") {
		super();
		this.url = url;
		this.method = method;
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken, "content-type": "application/json" };
		this.socket = { remoteAddress: "127.0.0.1" };
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

function agentOf(cwd) {
	return {
		id: "sess-1",
		session: { id: "sess-1", header: { id: "sess-1", cwd, createdAt: 1 } },
		header: { id: "sess-1", cwd, createdAt: 1 },
		events: [],
	};
}

/** 直接驱动注册的 /m/api 处理器（回调式，需等 finish 事件）。 */
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

/**
 * @param {object} opts
 * @param {object} [opts.agents]          注入 agents 服务（无活跃父 agent 时传 get:()=>undefined）
 * @param {object} [opts.sessions]        注入 sessions 服务（活跃分支用它查 header.createdAt）
 * @param {object} [opts.sessionQuery]    注入 sessionQuery（持久化分支）
 * @param {object} [opts.subagentList]    内核 subagents/list 的返回
 */
function createHarness({ agents, sessions, sessionQuery, subagentList, catalog } = {}) {
	const routes = [];
	const provided = new Map();
	if (agents !== undefined) provided.set("agents", agents);
	if (sessions !== undefined) provided.set("sessions", sessions);
	if (sessionQuery !== undefined) provided.set("sessionQuery", sessionQuery);
	// issue #21：子代理目录取代 `subagents/list` RPC（该端点在宿主 0.2.0 已删除）。
	// 目录条目形状 `{ id, createdAt, mode, label? }`，**不含状态**——状态另取活 agent。
	if (catalog !== undefined) provided.set("subagents", { listChildren: async () => catalog });
	provided.set("typertGateway", {
		async invokeRpc(endpoint) {
			if (endpoint === "subagents/list") {
				return { ok: true, value: subagentList ?? { entries: [], parentAvailable: true } };
			}
			return { ok: true, value: {} };
		},
		async dispatchRpc() {
			return { ok: true, value: undefined };
		},
		// 形参个数即代际（插件按 `.length` 判别取消信号的位次）；3 个 = 旧代签名。
		async openWireStream(endpoint, payload, signal) {
			return (async function* () {
				yield { type: "ready", clientId: "c-1" };
				// 真实 `$events` 流**不会自行结束**。若让生成器直接返回，插件会（正确地）按
				// "断开"处理并进入退避重连——而 issue #19 之后"曾经就绪"的通道是**无限**重连，
				// 于是测试进程永远无法退出（表现为整文件挂住、报 Promise resolution is pending）。
				if (signal && !signal.aborted) {
					await new Promise((resolve) => {
						signal.addEventListener("abort", resolve, { once: true });
					});
				}
			})();
		},
	});
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
		get(name) {
			return provided.get(name);
		},
		provide(name, value) {
			provided.set(name, value);
		},
		on() {
			return () => {};
		},
		effect(callback) {
			const disposer = callback?.();
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
		waterfall: async () => "unavailable",
	};
	const dispose = apply(ctx, CONFIG);
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		clean() {
			dispose?.();
		},
	};
}

/** 构造内核 subagent.list 的返回（故意用升序，模拟内核行为）。 */
function kernelList(entries) {
	return { entries, parentAvailable: true };
}

const ACTIVE_AGENTS = { get: (id) => (id === "sess-1" ? agentOf("C:\\ws") : undefined), roots: () => [] };
const DORMANT_AGENTS = { get: () => undefined, roots: () => [] };

// ───────────────────────── 1. 活跃分支 ─────────────────────────

test("活跃分支：按 createdAt 降序输出，并透出 createdAt", async () => {
	const createdAt = { "child-a": 1000, "child-b": 3000, "child-c": 2000 };
	const harness = createHarness({
		agents: ACTIVE_AGENTS,
		sessions: { get: (id) => ({ header: { id, createdAt: createdAt[id] } }) },
		catalog: [
			{ id: "child-a", createdAt: createdAt["child-a"], mode: "one-shot", label: "A" },
			{ id: "child-c", createdAt: createdAt["child-c"], mode: "one-shot", label: "C" },
			{ id: "child-b", createdAt: createdAt["child-b"], mode: "one-shot", label: "B" },
		],
	});
	try {
		const res = await call(harness.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		assert.equal(res.status, 200);
		assert.deepEqual(res.body.subagents.map((s) => s.id), ["child-b", "child-c", "child-a"]);
		assert.equal(res.body.subagents[0].createdAt, 3000);
		assert.equal(res.body.subagents[2].createdAt, 1000);
	} finally {
		harness.clean();
	}
});

test("活跃分支：状态取自活 agent（AgentStatus），非活回落 inactive", async () => {
	const harness = createHarness({
		agents: {
			// child-run 在活注册表里：状态应取它的 AgentStatus（内核取值 'idle' | 'running'）
			get: (id) => (id === "sess-1" ? agentOf("C:\\ws") : (id === "child-run" ? { id, session: { id }, status: "running" } : undefined)),
			roots: () => [],
		},
		sessions: { get: () => undefined },
		catalog: [
			{ id: "child-run", createdAt: 2000, mode: "one-shot", label: "R" },
			{ id: "child-quiet", createdAt: 1000, mode: "one-shot", label: "Q" },
		],
	});
	try {
		const res = await call(harness.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		const byId = new Map(res.body.subagents.map((s) => [s.id, s]));
		// 目录条目本身**不带状态**，故状态取自活 agent 的 AgentStatus
		// （内核取值 'idle' | 'running'）；不在活注册表里的子代理回落 "inactive"。
		assert.equal(byId.get("child-run").status, "running");
		assert.equal(byId.get("child-quiet").status, "inactive");
		assert.equal(byId.get("child-run").createdAt, 2000);
		assert.equal(byId.get("child-quiet").createdAt, 1000);
	} finally {
		harness.clean();
	}
});

test("活跃分支：缺 createdAt 的排最后，等值时按 id 升序稳定", async () => {
	const harness = createHarness({
		agents: ACTIVE_AGENTS,
		sessions: { get: (id) => (id === "child-tie-b" || id === "child-tie-a" ? { header: { id, createdAt: 5000 } } : undefined) },
		catalog: [
			// child-notime 刻意**不带** createdAt：应排最后（与 issue #17 的约定一致）
			{ id: "child-notime", mode: "one-shot", label: "N" },
			{ id: "child-tie-b", createdAt: 5000, mode: "one-shot", label: "TB" },
			{ id: "child-tie-a", createdAt: 5000, mode: "one-shot", label: "TA" },
		],
	});
	try {
		const res = await call(harness.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		assert.deepEqual(res.body.subagents.map((s) => s.id), ["child-tie-a", "child-tie-b", "child-notime"]);
	} finally {
		harness.clean();
	}
});

// ───────────────────────── 2. 休眠分支 ─────────────────────────

test("休眠分支：与活跃分支同一顺序，并透出 createdAt", async () => {
	const records = [
		{ header: { id: "sess-1", createdAt: 1 } },
		{ header: { id: "child-old", origin: "subagent", parentSession: "sess-1", createdAt: 1000 } },
		{ header: { id: "child-new", origin: "subagent", parentSession: "sess-1", createdAt: 3000 } },
		{ header: { id: "child-mid", origin: "subagent", parentSession: "sess-1", createdAt: 2000 } },
		// 非本父会话的子代理不应出现
		{ header: { id: "other-child", origin: "subagent", parentSession: "sess-OTHER", createdAt: 9000 } },
	];
	const harness = createHarness({
		agents: DORMANT_AGENTS,
		sessionQuery: {
			async listSessions() {
				return records;
			},
			async readTitleSnapshots(ids) {
				return ids.map(() => ({ status: "fulfilled", value: { title: { title: undefined } } }));
			},
		},
	});
	try {
		const res = await call(harness.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		assert.equal(res.status, 200);
		assert.deepEqual(res.body.subagents.map((s) => s.id), ["child-new", "child-mid", "child-old"]);
		assert.equal(res.body.subagents[0].createdAt, 3000);
		assert.equal(res.body.subagents[2].createdAt, 1000);
	} finally {
		harness.clean();
	}
});

test("两个分支对同一组子代理给出相同顺序（修掉顺序相反的缺陷）", async () => {
	const times = { "child-a": 1000, "child-b": 3000, "child-c": 2000 };
	const entries = [
		{ id: "child-a", createdAt: times["child-a"], mode: "one-shot", label: "A" },
		{ id: "child-c", createdAt: times["child-c"], mode: "one-shot", label: "C" },
		{ id: "child-b", createdAt: times["child-b"], mode: "one-shot", label: "B" },
	];
	const active = createHarness({
		agents: ACTIVE_AGENTS,
		sessions: { get: (id) => ({ header: { id, createdAt: times[id] } }) },
		catalog: entries,
	});
	const dormant = createHarness({
		agents: DORMANT_AGENTS,
		sessionQuery: {
			async listSessions() {
				return [
					{ header: { id: "sess-1", createdAt: 1 } },
					...Object.keys(times).map((id) => ({ header: { id, origin: "subagent", parentSession: "sess-1", createdAt: times[id] } })),
				];
			},
			async readTitleSnapshots(ids) {
				return ids.map(() => ({ status: "fulfilled", value: {} }));
			},
		},
	});
	try {
		const a = await call(active.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		const d = await call(dormant.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		const idsOf = (r) => r.body.subagents.map((s) => s.id);
		assert.deepEqual(idsOf(a), ["child-b", "child-c", "child-a"]);
		assert.deepEqual(idsOf(d), idsOf(a));
	} finally {
		active.clean();
		dormant.clean();
	}
});
