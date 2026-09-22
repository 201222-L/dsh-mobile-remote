/**
 * PR #11 P0/P1/P2 回归测试（v3.1.5）。
 *
 * 覆盖四组：
 *  1. `validateQuestionAnswers` 的答案校验矩阵（纯函数）；
 *  2. RPC 端点/实参：subagent.* → subagents/*、goal.* → goals/*（经真实 /api 处理器 + 假网关断言发往内核的
 *     endpoint 与 args 形状）；
 *  3. /respond 归属与结构校验：非法 400 且 pending 保留、sessionId 缺失仍宽容接受、
 *     取消走 UserQuestionError/ASK_CANCELLED 的 `$events/result` rejection（不再送 value:null）；
 *  4. /files/upload：指定会话解析失败不再回退首个工作区根（404）、文件名黑名单含 NUL。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply, validateQuestionAnswers } from "../lib/index.js";

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

const QUESTION = { id: "cleanup", question: "Delete them?", options: [{ label: "Yes" }, { label: "No" }], multiSelect: false };
const QUESTION_FRAME = {
	type: "waterfall",
	event: "user-questions/request",
	eventId: "ev-q",
	agentId: "session-A",
	request: { questions: [QUESTION] },
};
const APPROVAL_FRAME = {
	type: "waterfall",
	event: "approval/request",
	eventId: "ev-a",
	agentId: "session-A",
	request: { toolName: "write", callId: "call-1", reason: "test" },
};

/** 假宿主 ctx + 假 typertGateway（记录发往内核的 endpoint/args）。 */
function createHarness({ agents, goals, workspaceRegistry, frames = [] } = {}) {
	const routes = [];
	const provided = new Map();
	const logs = { warn: [], info: [] };
	const rpcCalls = [];
	const rpcDispatch = [];
	if (agents !== undefined) provided.set("agents", agents);
	if (goals !== undefined) provided.set("goals", goals);
	if (workspaceRegistry !== undefined) provided.set("workspaceRegistry", workspaceRegistry);
	provided.set("typertGateway", {
		async invokeRpc(endpoint, payload) {
			rpcCalls.push({ endpoint, args: payload?.args });
			return { ok: true, value: {} };
		},
		async dispatchRpc(endpoint, payload) {
			rpcDispatch.push({ endpoint, args: payload?.args });
			return { ok: true, value: undefined };
		},
		async openWireStream() {
			return (async function* frames_() {
				yield { type: "ready", clientId: "c-1" };
				for (const frame of frames) yield frame;
			})();
		},
	});
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
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		rpcCalls,
		rpcDispatch,
		logs,
		clean() { dispose?.(); },
	};
}

/** 直接驱动注册的 /m/api 处理器（GET/POST 皆可）。 */
async function call(route, { url, method = "GET", body } = {}) {
	const req = new FakeRequest(url, method);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	if (body !== undefined) {
		// readBody 在处理器首个 await 链上同步挂好监听，故下一微任务再喂数据
		queueMicrotask(() => {
			req.emit("data", Buffer.from(JSON.stringify(body), "utf8"));
			req.emit("end");
		});
	}
	await finished;
	return { status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") };
}

async function waitFor(predicate, message = "条件超时", timeoutMs = 2000) {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (predicate()) return;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	throw new Error(message);
}

/** 等 $events 帧被处理完（插件在 onEventsWaterfall 里同步打 info 日志）。 */
const waitForFrames = (harness, count) =>
	waitFor(() => harness.logs.info.filter((line) => line.includes("双端呈现")).length >= count, "等待 $events 帧处理超时");

const agentOf = (cwd) => ({ id: "session-A", session: { header: { cwd } } });

// ───────────────────────── 1. 答案校验矩阵 ─────────────────────────

test("validateQuestionAnswers：合法形状（单选 / 多选 / 纯自定义）", () => {
	const multi = { id: "tags", question: "Tags?", options: [{ label: "a" }, { label: "b" }], multiSelect: true };
	assert.deepEqual(validateQuestionAnswers([QUESTION], [{ id: "cleanup", selected: ["Yes"] }]), { ok: true });
	assert.deepEqual(validateQuestionAnswers([multi], [{ id: "tags", selected: ["a", "b"] }]), { ok: true });
	assert.deepEqual(validateQuestionAnswers([QUESTION], [{ id: "cleanup", selected: [], custom: "neither" }]), { ok: true });
	assert.deepEqual(validateQuestionAnswers([multi], [{ id: "tags", selected: ["a"], custom: "plus" }]), { ok: true });
});

test("validateQuestionAnswers：selected 缺失/null 一律拒绝（内核 [...selected] 会 TypeError）", () => {
	for (const selected of [undefined, null, "Yes", 1, {}]) {
		const answer = { id: "cleanup" };
		if (selected !== undefined) answer.selected = selected;
		const result = validateQuestionAnswers([QUESTION], [answer]);
		assert.equal(result.ok, false, `selected=${JSON.stringify(selected)} 必须被拒绝`);
		assert.equal(result.code, "question-answer-invalid");
	}
});

test("validateQuestionAnswers：数量 / id / custom / 选项 / 单选多选约束", () => {
	const cases = [
		{ name: "答案数与问题数不符", answers: [{ id: "cleanup", selected: ["Yes"] }, { id: "cleanup", selected: ["Yes"] }] },
		{ name: "缺少某问答案", answers: [{ id: "other", selected: ["Yes"] }] },
		{ name: "id 重复", answers: [{ id: "cleanup", selected: ["Yes"] }, { id: "cleanup", selected: ["No"] }], questions: [QUESTION, QUESTION] },
		{ name: "custom 非字符串", answers: [{ id: "cleanup", selected: [], custom: 42 }] },
		{ name: "selected 含非字符串", answers: [{ id: "cleanup", selected: [7] }] },
		{ name: "选项未声明", answers: [{ id: "cleanup", selected: ["Maybe"] }] },
		{ name: "单选多选了", answers: [{ id: "cleanup", selected: ["Yes", "No"] }] },
		{ name: "单选既选又自定义", answers: [{ id: "cleanup", selected: ["Yes"], custom: "x" }] },
		{ name: "未作答", answers: [{ id: "cleanup", selected: [] }] },
		{ name: "选项重复", answers: [{ id: "cleanup", selected: ["Yes", "Yes"] }] },
	];
	for (const { name, answers, questions } of cases) {
		const result = validateQuestionAnswers(questions ?? [QUESTION], answers);
		assert.equal(result.ok, false, `${name} 必须被拒绝`);
		assert.equal(result.code, "question-answer-invalid");
		assert.equal(typeof result.detail, "string");
	}
	assert.equal(validateQuestionAnswers([], []).ok, false, "无题目应拒绝");
	assert.equal(validateQuestionAnswers([QUESTION], "nope").ok, false, "answers 非数组应拒绝");
});

// ───────────────────────── 2. RPC 端点 / 实参 ─────────────────────────

test("subagent.* → 内核 subagents/* 命名空间与 wire 字段", async () => {
	const harness = createHarness({ agents: { get: (id) => (id === "sess-1" ? agentOf("C:\\ws") : undefined), roots: () => [] } });
	try {
		const list = await call(harness.route, { url: "/m/api/subagents?parentSessionId=sess-1" });
		assert.equal(list.status, 200);
		assert.deepEqual(harness.rpcCalls.at(-1), { endpoint: "subagents/list", args: { parentSessionId: "sess-1" } });

		const interrupt = await call(harness.route, {
			url: "/m/api/subagents/interrupt",
			method: "POST",
			body: { parentSessionId: "sess-1", childSessionId: "child-1" },
		});
		assert.equal(interrupt.status, 200);
		assert.deepEqual(harness.rpcCalls.at(-1), {
			endpoint: "subagents/interruptByParent",
			args: { childSessionId: "child-1", parentSessionId: "sess-1", mode: "continuable" },
		});
	} finally {
		harness.clean();
	}
});

test("goal.* → 内核 goals/* 命名空间、agentId + request/ref 形状", async () => {
	const harness = createHarness({
		agents: { get: (id) => (id === "session-A" ? agentOf("C:\\ws") : undefined), roots: () => [] },
		goals: { get: async () => ({ id: "goal-1", revision: 3 }) },
	});
	try {
		const created = await call(harness.route, {
			url: "/m/api/goal",
			method: "POST",
			body: { action: "create", sessionId: "session-A", objective: "ship it", maxGoalRounds: 5 },
		});
		assert.equal(created.status, 200);
		assert.deepEqual(harness.rpcCalls.at(-1), {
			endpoint: "goals/create",
			args: { agentId: "session-A", request: { objective: "ship it", maxGoalRounds: 5 } },
		});

		// 未给 maxGoalRounds 时不得出现该键（内核 request 是严格对象，undefined 字段会被边界校验拒绝）
		const minimal = await call(harness.route, {
			url: "/m/api/goal",
			method: "POST",
			body: { action: "create", sessionId: "session-A", objective: "minimal" },
		});
		assert.equal(minimal.status, 200);
		assert.deepEqual(harness.rpcCalls.at(-1), {
			endpoint: "goals/create",
			args: { agentId: "session-A", request: { objective: "minimal" } },
		});

		for (const action of ["pause", "resume", "complete"]) {
			const result = await call(harness.route, {
				url: "/m/api/goal",
				method: "POST",
				body: { action, sessionId: "session-A" },
			});
			assert.equal(result.status, 200, `${action} 应 200`);
			assert.deepEqual(harness.rpcCalls.at(-1), {
				endpoint: `goals/${action}`,
				args: { agentId: "session-A", ref: { id: "goal-1", revision: 3 } },
			});
		}
	} finally {
		harness.clean();
	}
});

// ───────────────────────── 3. /respond 校验与结算 ─────────────────────────

test("/respond：非法答案 400 且 pending 保留，随后合法答案仍可结算", async () => {
	const harness = createHarness({ frames: [QUESTION_FRAME] });
	try {
		await waitForFrames(harness, 1);
		const invalid = [
			{ answers: [{ id: "cleanup", selected: null }], name: "selected=null" },
			{ answers: [{ id: "cleanup" }], name: "缺 selected" },
			{ answers: [{ id: "cleanup", selected: ["Maybe"] }], name: "未声明选项" },
			{ answers: [{ id: "cleanup", selected: ["Yes", "No"] }], name: "单选多选" },
			{ answers: [{ id: "cleanup", selected: [] }], name: "未作答" },
			{ answers: [], name: "空数组" },
		];
		for (const { answers, name } of invalid) {
			const result = await call(harness.route, {
				url: "/m/api/respond",
				method: "POST",
				body: { kind: "question", rpcId: "ev-q", sessionId: "session-A", answers },
			});
			assert.equal(result.status, 400, `${name} 应 400`);
			assert.equal(result.body.error, "question-answer-invalid", `${name} 错误码`);
			assert.equal(harness.rpcDispatch.length, 0, `${name} 不得向内核发结算回执`);
		}
		// pending 保留：合法答案随后仍能结算成功
		const ok = await call(harness.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "question", rpcId: "ev-q", sessionId: "session-A", answers: [{ id: "cleanup", selected: ["Yes"] }] },
		});
		assert.equal(ok.status, 200);
		assert.deepEqual(harness.rpcDispatch.at(-1), {
			endpoint: "$events/result",
			args: {
				clientId: "c-1",
				eventId: "ev-q",
				outcome: { kind: "result", value: { answers: [{ id: "cleanup", selected: ["Yes"] }] } },
			},
		});
	} finally {
		harness.clean();
	}
});

test("/respond：sessionId 不匹配 400，缺失则宽容接受（兼容旧版 App）", async () => {
	const mismatch = createHarness({ frames: [QUESTION_FRAME] });
	try {
		await waitForFrames(mismatch, 1);
		const denied = await call(mismatch.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "question", rpcId: "ev-q", sessionId: "session-B", answers: [{ id: "cleanup", selected: ["Yes"] }] },
		});
		assert.equal(denied.status, 400);
		assert.equal(denied.body.error, "session-mismatch");
		assert.equal(mismatch.rpcDispatch.length, 0, "错会话不得结算");
	} finally {
		mismatch.clean();
	}

	const lenient = createHarness({ frames: [QUESTION_FRAME] });
	try {
		await waitForFrames(lenient, 1);
		const accepted = await call(lenient.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "question", rpcId: "ev-q", answers: [{ id: "cleanup", selected: ["Yes"] }] },
		});
		assert.equal(accepted.status, 200, "缺少 sessionId 必须宽容接受");
		assert.ok(lenient.logs.warn.some((line) => line.includes("缺少 sessionId")), "应记录兼容告警");
		assert.equal(lenient.rpcDispatch.at(-1).args.eventId, "ev-q");
	} finally {
		lenient.clean();
	}
});

test("/respond：取消问询发 rejection（{kind,error} + ASK_CANCELLED），不再送 value:null", async () => {
	const harness = createHarness({ frames: [QUESTION_FRAME] });
	try {
		await waitForFrames(harness, 1);
		const result = await call(harness.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "cancel", rpcId: "ev-q", sessionId: "session-A" },
		});
		assert.equal(result.status, 200);
		const dispatch = harness.rpcDispatch.at(-1);
		assert.equal(dispatch.endpoint, "$events/result");
		assert.equal(dispatch.args.eventId, "ev-q");
		// 网关 parseRemoteEventResult 只接受 {kind:error} 精确键、parseRemoteEventRejection 只接受
		// name/message + 可选 code/details —— 形状必须逐键对齐
		assert.deepEqual(Object.keys(dispatch.args.outcome).sort(), ["error", "kind"]);
		assert.equal(dispatch.args.outcome.kind, "rejected");
		assert.deepEqual(Object.keys(dispatch.args.outcome.error).sort(), ["code", "message", "name"]);
		assert.equal(dispatch.args.outcome.error.name, "UserQuestionError");
		assert.equal(dispatch.args.outcome.error.code, "ASK_CANCELLED");
		assert.equal(typeof dispatch.args.outcome.error.message, "string");
		assert.ok(!("value" in dispatch.args.outcome), "不得出现 value:null 结果形态");
	} finally {
		harness.clean();
	}
});

test("/respond：未知 approval outcome 400，合法 outcome 正常结算", async () => {
	const harness = createHarness({ frames: [APPROVAL_FRAME] });
	try {
		await waitForFrames(harness, 1);
		const bogus = await call(harness.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "approval", rpcId: "ev-a", sessionId: "session-A", outcome: "maybe" },
		});
		assert.equal(bogus.status, 400);
		assert.equal(bogus.body.error, "approval-outcome-invalid");
		assert.equal(harness.rpcDispatch.length, 0, "非法 outcome 不得结算");

		const allowed = await call(harness.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "approval", rpcId: "ev-a", sessionId: "session-A", outcome: "allowed-once" },
		});
		assert.equal(allowed.status, 200);
		assert.deepEqual(harness.rpcDispatch.at(-1).args.outcome, { kind: "result", value: "allowed-once" });
	} finally {
		harness.clean();
	}
});

test("审批取消仍发 cancelled（内核 OUTCOMES 合法值）", async () => {
	const harness = createHarness({ frames: [APPROVAL_FRAME] });
	try {
		await waitForFrames(harness, 1);
		const result = await call(harness.route, {
			url: "/m/api/respond",
			method: "POST",
			body: { kind: "cancel", rpcId: "ev-a", sessionId: "session-A" },
		});
		assert.equal(result.status, 200);
		assert.deepEqual(harness.rpcDispatch.at(-1).args.outcome, { kind: "result", value: "cancelled" });
	} finally {
		harness.clean();
	}
});

// ───────────────────────── 4. 上传目标目录 ─────────────────────────

test("/files/upload：指定会话解析失败 → 404，不再回退首个工作区根", async () => {
	const workspace = mkdtempSync(join(tmpdir(), "mobile-remote-ws-"));
	let registryListed = 0;
	const harness = createHarness({
		agents: { get: () => undefined, roots: () => [] },
		workspaceRegistry: { list: () => { registryListed += 1; return [{ path: workspace }]; } },
	});
	try {
		const result = await call(harness.route, {
			url: "/m/api/files/upload",
			method: "POST",
			body: { sessionId: "dormant-session", name: "leak.txt", data: Buffer.from("hi").toString("base64") },
		});
		assert.equal(result.status, 404);
		assert.equal(result.body.error, "session-not-found");
		assert.equal(registryListed, 0, "不得回退到工作区根");
		assert.equal(existsSync(join(workspace, "leak.txt")), false, "不得写入未指定的工作区");
	} finally {
		harness.clean();
	}
});

test("/files/upload：无 sessionId 仍写工作区根（行为未回归）", async () => {
	const workspace = mkdtempSync(join(tmpdir(), "mobile-remote-ws-"));
	const harness = createHarness({ workspaceRegistry: { list: () => [{ path: workspace }] } });
	try {
		const result = await call(harness.route, {
			url: "/m/api/files/upload",
			method: "POST",
			body: { name: "ok.txt", data: Buffer.from("hi").toString("base64") },
		});
		assert.equal(result.status, 200);
		assert.equal(readFileSync(join(workspace, "ok.txt"), "utf8"), "hi");
	} finally {
		harness.clean();
	}
});

test("/files/upload：文件名黑名单含 NUL", async () => {
	const harness = createHarness({ workspaceRegistry: { list: () => [{ path: mkdtempSync(join(tmpdir(), "mobile-remote-ws-")) }] } });
	try {
		const result = await call(harness.route, {
			url: "/m/api/files/upload",
			method: "POST",
			body: { name: "bad\u0000name.txt", data: Buffer.from("hi").toString("base64") },
		});
		assert.equal(result.status, 400);
		assert.equal(result.body.error, "invalid-name");
	} finally {
		harness.clean();
	}
});
