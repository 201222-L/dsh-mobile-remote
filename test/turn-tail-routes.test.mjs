/**
 * issue #53：轮末产出物契约的 HTTP 级测试（docs/03-api.md §6.20–§6.23）。
 *
 * 覆盖：`deliverables/presented` 投影（不下发主机路径）、`workspace/changes` 移出移动
 * 时间线、`turnTails`/`tail` 信号、`turnTail` 能力位，以及 `/changes/summary`、
 * `/changes/diff`、`/turn-file` 三个端点的成功/三态/错误码/Range 语义。
 *
 * 测试通过插件真实的 `apply(ctx, CONFIG)` 取得 `/m/api` 处理器，用假 req/res 直接驱动
 * （与 session-files-routes.test.mjs 同一 seam，无需起真实服务器）。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { apply, mobileDisplayPath, renderUnifiedDiffText, turnTailCapabilityOf, turnTailOf, turnTailsOf } from "../lib/index.js";

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
		this.statusCode = 0;
		this.headers = {};
		this.chunks = [];
		this.writableEnded = false;
	}
	writeHead(statusCode, headers = {}) {
		this.statusCode = statusCode;
		this.headers = headers;
		this.headersSent = true;
	}
	write(chunk) {
		this.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
		return true;
	}
	end(chunk = "") {
		if (chunk !== "") this.write(chunk);
		this.writableEnded = true;
		this.emit("finish");
	}
	destroy() {
		this.destroyed = true;
		this.emit("close");
	}
}

class FakeRequest extends EventEmitter {
	constructor(url, method = "GET", headers = {}) {
		super();
		this.url = url;
		this.method = method;
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken, ...headers };
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

/** 造一个临时工作区；返回绝对路径。 */
function makeWorkspace() {
	const root = mkdtempSync(join(tmpdir(), "turn-tail-"));
	mkdirSync(join(root, "src"));
	mkdirSync(join(root, "rel"));
	writeFileSync(join(root, "src", "a.ts"), "const a = 1;\n");
	writeFileSync(join(root, "rel", "inside.txt"), "inside\n");
	return root;
}

function makeWorkspaceChanges(root, { absentSummary = false } = {}) {
	const summary = {
		turn: 2,
		// 宿主摘要里的 cwd/path 只能用于服务端解析，绝不能出现在响应里。
		cwd: root,
		files: [
			{ path: "src/a.ts", display: "src/a.ts", added: 12, deleted: 3 },
			{ path: "bin.dat", display: "bin.dat", added: 0, deleted: 0, binary: true },
		],
		total: 2,
		added: 12,
		deleted: 3,
	};
	const diffs = new Map([
		[0, {
			kind: "text", path: "src/a.ts", display: "src/a.ts", before: true, after: true, coarse: false,
			hunks: [{ oldStart: 1, oldLines: 1, newStart: 1, newLines: 2, lines: ["-const a = 0;", "+const a = 1;", "+const b = 2;"] }],
		}],
		[1, { kind: "binary", path: "bin.dat", display: "bin.dat" }],
	]);
	return {
		summary,
		service: {
			summary(sessionId, seq) {
				if (absentSummary) return undefined;
				return sessionId === "s1" && seq === 2 ? summary : undefined;
			},
			async diff(sessionId, seq, index) {
				if (sessionId !== "s1" || seq !== 2) return undefined;
				return diffs.get(index);
			},
		},
	};
}

function createHarness({ workspaceChanges, sessions, sessionQuery, withSessions = true } = {}) {
	const routes = [];
	const hooks = new Map();
	const provided = new Map();
	if (withSessions) provided.set("sessions", sessions ?? { get: () => undefined });
	if (sessionQuery) provided.set("sessionQuery", sessionQuery);
	if (workspaceChanges) provided.set("workspaceChanges", workspaceChanges);
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on(event, fn) { hooks.set(event, fn); return () => hooks.delete(event); },
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
		hooks,
		clean() { dispose?.(); },
	};
}

async function call(route, { url, method = "GET", headers = {} } = {}) {
	const req = new FakeRequest(url, method, headers);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	const text = Buffer.concat(res.chunks).toString("utf8");
	let body;
	try { body = JSON.parse(text); } catch { body = text; }
	return { status: res.statusCode, headers: res.headers, body, raw: Buffer.concat(res.chunks), text };
}

/** 标准夹具：live 会话 s1 + 轮末事件 + 临时工作区文件 + 假 workspaceChanges。 */
function makeFixture({ absentSummary = false } = {}) {
	const root = makeWorkspace();
	const outsideRoot = mkdtempSync(join(tmpdir(), "turn-tail-outside-"));
	const outside = join(outsideRoot, "秘密报告.pdf");
	writeFileSync(outside, "PDF-BYTES");
	const gone = join(root, "gone.txt");
	const events = [
		{ seq: 1, type: "turn/start", data: { turn: 2 } },
		{ seq: 2, type: "workspace/changes", data: { turn: 2 } },
		{
			seq: 3,
			type: "deliverables/presented",
			data: {
				turn: 2,
				callId: "call_present_1",
				files: [
					{ path: join(root, "src", "a.ts"), description: "最终交付" },
					{ path: outside, description: "外部文件" },
					{ path: "rel/inside.txt" },
					{ path: gone },
				],
			},
		},
		{ seq: 4, type: "turn/end", data: { turn: 2, reason: { kind: "completed" } } },
		{ seq: 5, type: "workspace/changes", data: { turn: 3 } },
	];
	const live = { id: "s1", header: { createdAt: 1, cwd: root }, events, snapshotEvents() { return this.events; } };
	const sessions = { get: (id) => (id === "s1" ? live : undefined), list: () => [live] };
	const changes = makeWorkspaceChanges(root, { absentSummary });
	return { root, outside, outsideRoot, gone, events, live, sessions, changes };
}

test("summary 投影：deliverables/presented 只下发 name/display/description", async () => {
	const f = makeFixture();
	const res = await call(createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route, {
		url: "/m/api/history?sessionId=s1&limit=100",
	});
	const presented = res.body.events.find((event) => event.type === "deliverables/presented");
	assert.ok(presented, "presented 事件应进入移动时间线");
	assert.deepEqual(presented.data.files.map((file) => file.name), ["a.ts", "秘密报告.pdf", "inside.txt", "gone.txt"]);
	const first = presented.data.files[0];
	assert.deepEqual(Object.keys(first).sort(), ["description", "display", "name"], "只允许 name/display/description");
	assert.equal(first.display, "src/a.ts", "工作目录内给相对路径");
	assert.equal(presented.data.files[1].display, "秘密报告.pdf", "工作区外只给 basename");
	assert.equal(presented.data.files[2].display, "rel/inside.txt");
	assert.equal(presented.data.turn, 2);
	assert.equal(presented.data.callId, "call_present_1");
});

test("history：响应不含主机绝对路径；workspace/changes 移出时间线但 turnTails 保留信号", async () => {
	const f = makeFixture();
	const res = await call(createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route, {
		url: "/m/api/history?sessionId=s1&limit=100",
	});
	assert.equal(res.status, 200);
	assert.deepEqual(res.body.turnTails, { "2": { changes: true, presented: true }, "3": { changes: true, presented: false } });
	assert.ok(!res.body.events.some((event) => event.type === "workspace/changes"), "workspace/changes 不进移动时间线");
	assert.ok(!res.text.includes(f.root), "响应不得包含会话工作目录");
	assert.ok(!res.text.includes(f.outside), "响应不得包含记录里的主机绝对路径");
});

test("event-detail：workspace/changes 与 delivered 原始声明 fail-closed", async () => {
	const f = makeFixture();
	const { route } = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service });
	const changesDetail = await call(route, { url: "/m/api/event-detail?sessionId=s1&seq=2" });
	assert.equal(changesDetail.status, 404, "workspace/changes 不在可见事件/详情 allow-list");
	const presentedDetail = await call(route, { url: "/m/api/event-detail?sessionId=s1&seq=3" });
	assert.equal(presentedDetail.status, 404, "presented 原始声明（含主机路径）不得经详情端点泄露");
});

test("turnTailCapabilityOf：按 workspaceChanges 服务真实存在与否判定", () => {
	const missing = turnTailCapabilityOf({ get: () => undefined });
	assert.deepEqual(missing, { version: 1, presented: true, changed: false, changesDiff: false });
	const broken = turnTailCapabilityOf({ get: () => ({ summary: 1, diff: 2 }) });
	assert.equal(broken.changed, false);
	const full = turnTailCapabilityOf({ get: () => ({ summary() {}, diff() {} }) });
	assert.deepEqual(full, { version: 1, presented: true, changed: true, changesDiff: true });
});

test("turnTailsOf/turnTailOf：单次遍历、只含有产出物的轮次", () => {
	const events = [
		{ type: "workspace/changes", data: { turn: 2 } },
		{ type: "deliverables/presented", data: { turn: 2, files: [{ path: "/tmp/a" }] } },
		{ type: "workspace/changes", data: { turn: 3 } },
		{ type: "deliverables/presented", data: { turn: 4, files: [] } },
		{ type: "workspace/changes", data: {} },
	];
	assert.deepEqual(turnTailsOf(events), { "2": { changes: true, presented: true }, "3": { changes: true, presented: false } });
	assert.deepEqual(turnTailOf(events, 3), { changes: true, presented: false });
	assert.equal(turnTailOf(events, 9), null);
	assert.equal(turnTailsOf([]).constructor, Object);
});

test("bootstrap：capabilities.turnTail 与能力判据一致", async () => {
	const f = makeFixture();
	const withService = await call(createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route, { url: "/m/api/bootstrap" });
	assert.deepEqual(withService.body.capabilities.turnTail, { version: 1, presented: true, changed: true, changesDiff: true });
	const without = await call(createHarness({ sessions: f.sessions }).route, { url: "/m/api/bootstrap" });
	assert.deepEqual(without.body.capabilities.turnTail, { version: 1, presented: true, changed: false, changesDiff: false });
});

test("SSE：hello 带同判据 turnTail，turn/end 摘要带 tail", async () => {
	const f = makeFixture();
	const harness = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service });
	const req = new FakeRequest("/m/api/events");
	const res = new FakeResponse();
	harness.route(req, res);
	await new Promise((resolve) => setTimeout(resolve, 10));
	const helloText = Buffer.concat(res.chunks).toString("utf8");
	assert.ok(helloText.includes('"turnTail":{"version":1,"presented":true,"changed":true,"changesDiff":true}'), helloText.slice(0, 400));
	const liveHook = harness.hooks.get("session/event");
	assert.equal(typeof liveHook, "function");
	liveHook(f.live, { seq: 4, type: "turn/end", data: { turn: 2, reason: { kind: "completed" } } });
	const liveText = Buffer.concat(res.chunks).toString("utf8");
	assert.ok(liveText.includes('"tail":{"changes":true,"presented":true}'), liveText.slice(-600));
	harness.clean();
});

test("changes/summary：available 映射（seq/index 坐标、截断、不泄露 path/cwd）", async () => {
	const f = makeFixture();
	const res = await call(createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route, {
		url: "/m/api/changes/summary?sessionId=s1&turn=2",
	});
	assert.equal(res.status, 200);
	assert.equal(res.body.state, "available");
	assert.equal(res.body.files[0].seq, 2);
	assert.equal(res.body.files[0].index, 0);
	assert.equal(res.body.files[0].display, "src/a.ts");
	assert.equal(res.body.files[0].name, "a.ts");
	assert.equal(res.body.files[0].added, 12);
	assert.equal(res.body.files[1].binary, true);
	assert.equal(res.body.total, 2);
	assert.equal(res.body.truncated, false);
	assert.ok(!("cwd" in res.body), "不得下发宿主 cwd");
	assert.ok(!("path" in res.body.files[0]), "不得下发可拼接 path");
});

test("changes/summary：absent / unavailable（休眠、服务缺失、摘要失效）", async () => {
	const f = makeFixture();
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route;
	const absent = await call(route, { url: "/m/api/changes/summary?sessionId=s1&turn=4" });
	assert.equal(absent.body.state, "absent");
	assert.deepEqual(absent.body.files, []);
	const dormant = await call(route, { url: "/m/api/changes/summary?sessionId=s-dormant&turn=2" });
	assert.equal(dormant.body.state, "unavailable");
	const noService = await call(createHarness({ sessions: f.sessions }).route, { url: "/m/api/changes/summary?sessionId=s1&turn=2" });
	assert.equal(noService.body.state, "unavailable");
	// 摘要失效（宿主重启）由 summary() 返回 undefined 表达 —— state 仍是 unavailable。
	const goneSummary = makeFixture({ absentSummary: true });
	const lostRes = await call(createHarness({ sessions: goneSummary.sessions, workspaceChanges: goneSummary.changes.service }).route, {
		url: "/m/api/changes/summary?sessionId=s1&turn=2",
	});
	assert.equal(lostRes.body.state, "unavailable");
	assert.equal(lostRes.status, 200);
});

test("changes/summary：参数错误与 sessions 服务缺失的稳定错误码", async () => {
	const f = makeFixture();
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route;
	assert.equal((await call(route, { url: "/m/api/changes/summary?sessionId=s1" })).status, 400);
	assert.equal((await call(route, { url: "/m/api/changes/summary?sessionId=s1&turn=-1" })).status, 400);
	assert.equal((await call(route, { url: "/m/api/changes/summary?turn=2" })).status, 400);
	const noSessions = createHarness({ withSessions: false }).route;
	assert.equal((await call(noSessions, { url: "/m/api/changes/summary?sessionId=s1&turn=2" })).status, 503);
});

test("changes/summary：200 上限截断并保留全量 total", async () => {
	const f = makeFixture();
	const many = makeWorkspaceChanges(f.root);
	many.summary.files = Array.from({ length: 250 }, (_, index) => ({ path: `f${index}.txt`, display: `f${index}.txt`, added: 1, deleted: 0 }));
	many.summary.total = 250;
	const res = await call(createHarness({ sessions: f.sessions, workspaceChanges: many.service }).route, {
		url: "/m/api/changes/summary?sessionId=s1&turn=2",
	});
	assert.equal(res.body.files.length, 200);
	assert.equal(res.body.total, 250);
	assert.equal(res.body.truncated, true);
});

test("changes/diff：hunks 渲染为统一 diff 文本", async () => {
	const f = makeFixture();
	const res = await call(createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route, {
		url: "/m/api/changes/diff?sessionId=s1&turn=2&index=0",
	});
	assert.equal(res.status, 200);
	assert.equal(res.body.diff.kind, "text");
	assert.equal(res.body.diff.display, "src/a.ts");
	assert.equal(res.body.diff.before, true);
	assert.equal(res.body.diff.truncated, false);
	const text = res.body.diff.diff;
	assert.ok(text.startsWith("--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,1 +1,2 @@"), text);
	assert.ok(text.includes("-const a = 0;") && text.includes("+const b = 2;"));
	assert.ok(!("path" in res.body.diff), "diff 不带主机 path");
	assert.ok(!res.text.includes(f.root));
});

test("changes/diff：binary / 404 / 400 / 503", async () => {
	const f = makeFixture();
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route;
	const binary = await call(route, { url: "/m/api/changes/diff?sessionId=s1&turn=2&index=1" });
	assert.equal(binary.status, 200);
	assert.equal(binary.body.diff.kind, "binary");
	const notFound = await call(route, { url: "/m/api/changes/diff?sessionId=s1&turn=2&index=9" });
	assert.equal(notFound.status, 404);
	assert.equal(notFound.body.error, "diff-not-found");
	const absent = await call(route, { url: "/m/api/changes/diff?sessionId=s1&turn=3&index=0" });
	assert.equal(absent.status, 404, "该轮没有 changes 事件 → diff-not-found");
	assert.equal((await call(route, { url: "/m/api/changes/diff?sessionId=s1&turn=2" })).status, 400);
	const noService = createHarness({ sessions: f.sessions }).route;
	assert.equal((await call(noService, { url: "/m/api/changes/diff?sessionId=s1&turn=2&index=0" })).status, 503);
});

test("turn-file：presented 文本字节 + Range/HEAD/ETag，且不接受客户端路径", async () => {
	const f = makeFixture();
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route;
	const url = "/m/api/turn-file?sessionId=s1&kind=presented&seq=3&index=0";
	const res = await call(route, { url });
	assert.equal(res.status, 200);
	assert.equal(res.raw.toString("utf8"), "const a = 1;\n");
	assert.equal(res.headers["connection"], "close");
	const ranged = await call(route, { url, headers: { range: "bytes=0-4" } });
	assert.equal(ranged.status, 206);
	assert.equal(ranged.raw.toString("utf8"), "const");
	const head = await call(route, { url, method: "HEAD" });
	assert.equal(head.status, 200);
	assert.ok(Number(head.headers["content-length"]) > 0);
	assert.equal(head.raw.length, 0);
	const etag = String(head.headers.etag);
	const cached = await call(route, { url, headers: { "if-none-match": etag } });
	assert.equal(cached.status, 304);
});

test("turn-file：presented 工作区外绝对路径、相对记录路径与休眠会话", async () => {
	const f = makeFixture();
	const query = {
		async readEvent({ sessionId, seq }) {
			if (sessionId !== "s-dormant" || seq !== 7) throw new Error("not indexed");
			return {
				session: { id: "s-dormant", cwd: f.root },
				target: { seq: 7, type: "deliverables/presented", data: { turn: 1, callId: "c", files: [{ path: "rel/inside.txt" }] } },
			};
		},
	};
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service, sessionQuery: query }).route;
	const outside = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=presented&seq=3&index=1" });
	assert.equal(outside.status, 200);
	assert.equal(outside.raw.toString("utf8"), "PDF-BYTES");
	const relative = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=presented&seq=3&index=2" });
	assert.equal(relative.status, 200);
	assert.equal(relative.raw.toString("utf8"), "inside\n");
	const dormant = await call(route, { url: "/m/api/turn-file?sessionId=s-dormant&kind=presented&seq=7&index=0" });
	assert.equal(dormant.status, 200, "休眠会话按 readEvent 的记录坐标读取");
	assert.equal(dormant.raw.toString("utf8"), "inside\n");
});

test("turn-file：changed 按摘要 seq/index 解析（不泄露路径）", async () => {
	const f = makeFixture();
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route;
	const res = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=changed&seq=2&index=0" });
	assert.equal(res.status, 200);
	assert.equal(res.raw.toString("utf8"), "const a = 1;\n");
	const binary = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=changed&seq=2&index=1" });
	assert.equal(binary.status, 404, "摘要中的路径不存在 → file-not-found");
	assert.equal(binary.body.error, "file-not-found");
});

test("turn-file：record-not-found / file-not-found / 503 / 400 且错误体脱敏", async () => {
	const f = makeFixture();
	const route = createHarness({ sessions: f.sessions, workspaceChanges: f.changes.service }).route;
	const badKind = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=other&seq=3&index=0" });
	assert.equal(badKind.status, 400);
	const badIndex = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=presented&seq=3&index=99" });
	assert.equal(badIndex.status, 404);
	assert.equal(badIndex.body.error, "record-not-found");
	const wrongSeq = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=presented&seq=1&index=0" });
	assert.equal(wrongSeq.status, 404);
	const deleted = await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=presented&seq=3&index=3" });
	assert.equal(deleted.status, 404);
	assert.equal(deleted.body.error, "file-not-found");
	assert.ok(!JSON.stringify(deleted.body).includes(f.root), "错误体不得回显主机路径");
	const noService = createHarness({ sessions: f.sessions }).route;
	assert.equal((await call(noService, { url: "/m/api/turn-file?sessionId=s1&kind=changed&seq=2&index=0" })).status, 503);
	assert.equal((await call(route, { url: "/m/api/turn-file?sessionId=s1&kind=presented&seq=3" })).status, 400);
});

test("纯函数：mobileDisplayPath / renderUnifiedDiffText", () => {
	// HOME 在不同环境（CI/verify 隔离）会变，家目录用例必须用运行时 homedir() 构造。
	const home = homedir();
	assert.equal(mobileDisplayPath(`${home}/proj/src/a.ts`, `${home}/proj`), "src/a.ts");
	assert.equal(mobileDisplayPath(`${home}/.config/x`, `${home}/proj`), "~/.config/x");
	assert.equal(mobileDisplayPath("/opt/other/y", "/home/mark/proj"), "y");
	assert.equal(mobileDisplayPath("rel/z.ts", undefined), "rel/z.ts");
	assert.equal(mobileDisplayPath("", "/tmp"), "");
	const truncated = renderUnifiedDiffText({
		display: "a.txt",
		before: false,
		after: true,
		hunks: [{ oldStart: 1, oldLines: 0, newStart: 1, newLines: 1, lines: ["+" + "x".repeat(600 * 1024)] }],
	});
	assert.equal(truncated.truncated, true);
	assert.ok(truncated.text.startsWith("--- /dev/null\n+++ b/a.txt\n@@ -1,0 +1,1 @@"));
});
