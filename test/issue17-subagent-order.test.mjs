// issue #17：子代理列表端点契约回归。
//
// 覆盖外部可观察行为：
//  1. 活跃父会话分支：条目带 `createdAt`，且按 createdAt **降序**输出
//     （内核 subagent.list 是升序，插件必须显式反转——否则与休眠分支顺序相反）；
//  2. 休眠/归档父会话分支：同样带 `createdAt` 且按同一规则降序，与活跃分支一致；
//  3. 缺 createdAt 的条目排在最后，等值时按 id 升序稳定；
//  4. `status` 仍原样透传内核 activity/diagnostic reason（本次不改其语义）。
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
function createHarness({ agents, sessions, sessionQuery, subagentList } = {}) {
	const routes = [];
	const provided = new Map();
	if (agents !== undefined) provided.set("agents", agents);
	if (sessions !== undefined) provided.set("sessions", sessions);
	if (sessionQuery !== undefined) provided.set("sessionQuery", sessionQuery);
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
		async openWireStream() {
			return (async function* () {
				yield { type: "ready", clientId: "c-1" };
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
		subagentList: kernelList([
			{ id: "child-a", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "A" },
			{ id: "child-c", kind: "child", activity: "running", hasChildren: false, mode: "one-shot", label: "C" },
			{ id: "child-b", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "B" },
		]),
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

test("活跃分支：保留 status 语义（原样透传 activity / diagnostic reason）", async () => {
	const harness = createHarness({
		agents: ACTIVE_AGENTS,
		sessions: { get: () => undefined },
		subagentList: kernelList([
			{ id: "child-run", kind: "child", activity: "running", hasChildren: false, mode: "one-shot", label: "R" },
			{ id: "child-diag", kind: "diagnostic", reason: "corrupt", hasChildren: false, mode: "one-shot" },
		]),
	});
	try {
		const res = await call(harness.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		const byId = new Map(res.body.subagents.map((s) => [s.id, s]));
		assert.equal(byId.get("child-run").status, "running");
		assert.equal(byId.get("child-diag").status, "corrupt");
		// 取不到 createdAt 时不应伪造数值
		assert.equal(byId.get("child-run").createdAt, undefined);
	} finally {
		harness.clean();
	}
});

test("活跃分支：缺 createdAt 的排最后，等值时按 id 升序稳定", async () => {
	const harness = createHarness({
		agents: ACTIVE_AGENTS,
		sessions: { get: (id) => (id === "child-tie-b" || id === "child-tie-a" ? { header: { id, createdAt: 5000 } } : undefined) },
		subagentList: kernelList([
			{ id: "child-notime", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "N" },
			{ id: "child-tie-b", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "TB" },
			{ id: "child-tie-a", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "TA" },
		]),
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
		{ id: "child-a", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "A" },
		{ id: "child-c", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "C" },
		{ id: "child-b", kind: "child", activity: "inactive", hasChildren: false, mode: "one-shot", label: "B" },
	];
	const active = createHarness({
		agents: ACTIVE_AGENTS,
		sessions: { get: (id) => ({ header: { id, createdAt: times[id] } }) },
		subagentList: kernelList(entries),
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
