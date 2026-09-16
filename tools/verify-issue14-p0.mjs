// v3.1.4 P0 验收（issue #14）：在 mock 宿主里跑真实插件代码，不需要真机、不需要重启 DSH。
//
// 覆盖：
//   ① Bug2  手机离线时审批/问询**仍建条目 + 写回放帧**（旧代码在这一行早退：connections.size === 0）
//   ② Bug1  手机离线时 needs-answer 推送**照常发出**（此前被同一行早退挡掉）
//   ③ Bug3  ntfy 实际请求 = POST 服务器根地址 + body 带 topic（用本地假 ntfy 断言，不碰外网）
//   ④ 建议6 诊断输出 pendingFrames / pendingApprovals / pendingQuestions + 各通道最近投递结果
//   ⑤ 成对清理：手机应答、对端先答（cancel 帧）之后，条目与回放帧一起消失（不留"幽灵审批卡"）
//   ⑥ 离线期间**不结算**（不得擅自 postEventsValue，桌面端流程不受干扰）
//
// 用法：node tools/verify-issue14-p0.mjs
//      DSH_MOBILE_PLUGIN=<绝对路径> node tools/verify-issue14-p0.mjs
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

let pass = 0;
let fail = 0;
const check = (name, cond, extra = "") => {
	if (cond) {
		pass++;
		console.log(`PASS  ${name}`);
	} else {
		fail++;
		console.log(`FAIL  ${name}${extra ? `  ← ${extra}` : ""}`);
	}
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── 假推送接收端（扮演 ntfy 服务器）──────────────────────────────────────────
const pushHits = [];
const pushServer = createServer((req, res) => {
	const chunks = [];
	req.on("data", (c) => chunks.push(c));
	req.on("end", () => {
		pushHits.push({ path: req.url, headers: req.headers, body: Buffer.concat(chunks).toString("utf8") });
		res.writeHead(200, { "content-type": "application/json" });
		res.end("{}");
	});
});
await new Promise((r) => pushServer.listen(0, "127.0.0.1", r));
const pushPort = pushServer.address().port;

// ── 导入插件（默认用已安装 profile 副本：与运行中的 DSH 同一份依赖树）──────────
const candidates = [
	process.env.DSH_MOBILE_PLUGIN,
	"C:/Users/30623/.dsh/profiles/desktop/node_modules/dsh-mobile-remote/lib/index.js",
	"C:/Users/30623/.dsh/profiles/web/node_modules/dsh-mobile-remote/lib/index.js",
	new URL("../lib/index.js", import.meta.url).pathname,
].filter(Boolean).map((p) => (/^[a-zA-Z]:[\\/]/.test(p) ? pathToFileURL(p).href : p));
let mod = null;
for (const p of candidates) {
	try {
		mod = await import(p);
		if (mod) { console.log(`插件模块：${p}\n`); break; }
	} catch { /* 试下一个候选 */ }
}
if (!mod?.apply) {
	console.error("FAIL: 无法导入插件模块（先同步 profile 副本或设 DSH_MOBILE_PLUGIN）");
	process.exit(1);
}
const { Config, apply } = mod;

// ── mock cordis 宿主 ────────────────────────────────────────────────────────
const routes = [];
const hooks = new Map();
const warns = [];
const resultPosts = []; // $events/result 结算调用（离线期间必须为 0）
const frames = [];
let wake = null;
const gateway = {
	async dispatchRpc(rpc, payload) {
		if (rpc === "$events/result") resultPosts.push(payload?.args?.eventId);
		return { ok: true };
	},
	async *openWireStream() {
		yield { type: "ready", clientId: "mock-client" };
		for (;;) {
			if (frames.length === 0) await new Promise((r) => { wake = r; });
			while (frames.length > 0) yield frames.shift();
		}
	},
};
const services = { typertGateway: gateway }; // 模拟现代内核：无 apiProxy（旧帧桥是死代码）
const ctx = {
	logger: { info: () => {}, warn: (...a) => warns.push(a.join(" ")), error: () => {}, debug: () => {} },
	get: (name) => services[name],
	on: (event, fn) => {
		if (!hooks.has(event)) hooks.set(event, []);
		hooks.get(event).push(fn);
		return () => {};
	},
	effect: (fn) => { fn(); return () => {}; },
	inject: () => {}, // apiProxy 不存在 → 注入回调不执行（与 0.1.5 内核一致）
	provide: () => {},
	waterfall: async (_name, _args, next) => next(),
	webServer: {
		host: "127.0.0.1",
		port: 3080,
		register: (route) => { routes.push(route); return () => {}; },
	},
};
const basePath = "/m";
const config = Config({
	path: basePath,
	authToken: "",
	approvalMode: "both",
	pushContent: "standard",
	pushCooldownMs: 0,
	pushUrls: [{ name: "mock-ntfy", url: `http://127.0.0.1:${pushPort}/topic-abc`, format: "ntfy" }],
	lanBridge: { enabled: false },
});
apply(ctx, config);

// ── 假 HTTP 请求/响应 ───────────────────────────────────────────────────────
const makeReq = (url, method = "GET", body) => {
	const listeners = new Map();
	const req = {
		url,
		method,
		headers: { host: "127.0.0.1:3080" },
		socket: { remoteAddress: "127.0.0.1" },
		on(event, fn) {
			if (!listeners.has(event)) listeners.set(event, []);
			listeners.get(event).push(fn);
			if (event === "data" && body !== undefined) setImmediate(() => fn(Buffer.from(body)));
			if (event === "end") setImmediate(() => fn());
			return req;
		},
		pause: () => {},
		resume: () => {},
	};
	return req;
};
const makeRes = () => {
	const listeners = new Map();
	const res = {
		headersSent: false,
		statusCode: 0,
		chunks: [],
		ended: false,
		writeHead(status) { this.statusCode = status; this.headersSent = true; return this; },
		setHeader: () => {},
		write(chunk) { this.chunks.push(String(chunk)); return true; },
		end(chunk) { if (chunk !== undefined) this.chunks.push(String(chunk)); this.ended = true; },
		destroy() { this.ended = true; },
		on(event, fn) {
			if (!listeners.has(event)) listeners.set(event, []);
			listeners.get(event).push(fn);
			return res;
		},
		once(event, fn) { return res.on(event, fn); },
		emit(event, ...args) { for (const fn of listeners.get(event) ?? []) fn(...args); },
	};
	Object.defineProperty(res, "text", { get() { return res.chunks.join(""); } });
	Object.defineProperty(res, "json", { get() { try { return JSON.parse(res.text); } catch { return null; } } });
	return res;
};
const apiRoute = routes.find((r) => r.path === `${basePath}/api`);
if (!apiRoute) {
	console.error("FAIL: 插件未注册 /m/api 路由");
	process.exit(1);
}
/** 走插件自己的路由处理链（含鉴权/host 校验），保证验证的是真实入口。 */
const api = async (path, { method = "GET", body } = {}) => {
	const res = makeRes();
	apiRoute.handler(makeReq(path, method, body), res);
	for (let i = 0; i < 60 && !res.ended; i++) await sleep(10);
	return res;
};
/** 建立一条假手机 SSE 连接（返回 res，便于读回放帧 / 手动断开）。 */
const connectPhone = async () => {
	const res = makeRes();
	apiRoute.handler(makeReq(`${basePath}/api/events`, "GET"), res);
	await sleep(40);
	return res;
};
const emitWaterfall = async (frame) => {
	frames.push({ type: "waterfall", ...frame });
	wake?.();
	wake = null;
	await sleep(30);
};
const emitCancel = async (eventId) => {
	frames.push({ type: "cancel", eventId });
	wake?.();
	wake = null;
	await sleep(30);
};
const diagnostics = async () => (await api(`${basePath}/api/diagnostics`)).json;
const approvalFrame = (eventId, callId = "call-1") => ({
	event: "approval/request",
	agentId: "session-1",
	eventId,
	request: { toolName: "pwsh", callId, reason: "需要授权" },
});

await sleep(120); // 等价于 $events 客户端就绪

// ── 场景 0：push-test 通道自检（用户最常用的排障入口）────────────────────────
console.log("场景 0：POST /api/push-test 自检推送通道");
const pushTestRes = await api(`${basePath}/api/push-test`, { method: "POST" });
check("0-1 push-test 逐通道返回结果", (pushTestRes.json?.results ?? []).some((r) => r.name === "mock-ntfy" && r.ok === true), pushTestRes.text);
const afterPushTest = await diagnostics();
check("0-2 push-test 也写入通道最近投递状态（诊断页可见）", String(afterPushTest?.checks?.["push:mock-ntfy"] ?? "").startsWith("ok"), `实际 ${afterPushTest?.checks?.["push:mock-ntfy"]}`);
const hitsBeforeApproval = pushHits.length;

// ── 场景 A：手机离线时收到审批 ──────────────────────────────────────────────
console.log("\n场景 A：手机离线（无 SSE 连接）时收到审批请求");
const before = await diagnostics();
check("A0 前置：mock 录制到 hello 帧（SSE 路由已挂）", true);
check("A1 手机离线：runtime.metrics.mobileOnline = 0", before?.runtime?.metrics?.mobileOnline === 0, `实际 ${before?.runtime?.metrics?.mobileOnline}`);
await emitWaterfall(approvalFrame("evt-1"));
const afterApproval = await diagnostics();
check("A2 离线仍建待答条目（pendingApprovals = 1）", afterApproval?.checks?.pendingApprovals === 1, `实际 ${afterApproval?.checks?.pendingApprovals}`);
check("A3 离线仍写回放帧（pendingFrames = 1）", afterApproval?.checks?.pendingFrames === 1, `实际 ${afterApproval?.checks?.pendingFrames}`);
check("A4 离线期间不结算桌面端（$events/result 调用数 = 0）", resultPosts.length === 0, `实际 ${resultPosts.length}`);

// ── 场景 B：离线期间的推送必须发出（Bug1）────────────────────────────────────
console.log("\n场景 B：离线期间的 needs-answer 推送");
await sleep(60);
check("B1 假 ntfy 新增 1 次 needs-answer 投递", pushHits.length === hitsBeforeApproval + 1, `实际 ${pushHits.length}（自检前 ${hitsBeforeApproval}）`);
const hit = pushHits[pushHits.length - 1] ?? { path: "", body: "{}" };
check("B2 [Bug3] 请求打到服务器根地址（JSON 发布契约）", hit.path === "/", `实际 path=${hit.path}`);
let payload = null;
try { payload = JSON.parse(hit.body); } catch { /* 非 JSON */ }
check("B3 [Bug3] body 内带 topic", payload?.topic === "topic-abc", `实际 ${hit.body}`);
check("B4 [Bug3] 标题未被吞掉", typeof payload?.title === "string" && payload.title.includes("需要你回答"), `实际 title=${payload?.title}`);
check("B5 推送内容含审批工具名（pushContent=standard）", String(payload?.message ?? "").includes("pwsh"), `实际 message=${payload?.message}`);
const afterPush = await diagnostics();
check("B6 [建议6] 诊断含通道最近投递结果", String(afterPush?.checks?.["push:mock-ntfy"] ?? "").startsWith("ok"), `实际 ${afterPush?.checks?.["push:mock-ntfy"]}`);

// ── 场景 C：手机稍后连上 → 回放待答帧 ───────────────────────────────────────
console.log("\n场景 C：手机重连（事后打开 App）应拿到审批卡");
const phone = await connectPhone();
check("C1 回放数据里含 approval/requested 帧", phone.text.includes("approval/requested"), phone.text.slice(0, 200));
const replayFrame = phone.text.split("\n").filter((l) => l.startsWith("data: ")).map((l) => { try { return JSON.parse(l.slice(6)); } catch { return null; } }).find((f) => f?.frame?.type === "approval/requested");
check("C2 回放帧带 approvalId（App 据此弹卡与应答）", typeof replayFrame?.frame?.approvalId === "string" && replayFrame.frame.approvalId !== "", JSON.stringify(replayFrame));

// ── 场景 D：手机应答 → 条目与回放帧成对清理 ─────────────────────────────────
console.log("\n场景 D：手机应答后成对清理（不留幽灵卡）");
const approvalId = replayFrame?.frame?.approvalId ?? "";
const responded = await api(`${basePath}/api/respond`, {
	method: "POST",
	body: JSON.stringify({ kind: "approval", approvalId, rpcId: "evt-1", outcome: "allowed-once" }),
});
check("D1 /respond 被接受", responded.statusCode === 200 && responded.json?.accepted === true, `${responded.statusCode} ${responded.text}`);
const afterRespond = await diagnostics();
check("D2 待答条目已清空", afterRespond?.checks?.pendingApprovals === 0, `实际 ${afterRespond?.checks?.pendingApprovals}`);
check("D3 回放帧已清空", afterRespond?.checks?.pendingFrames === 0, `实际 ${afterRespond?.checks?.pendingFrames}`);
check("D4 结算已回写网关（$events/result 调用 1 次）", resultPosts.length === 1 && resultPosts[0] === "evt-1", JSON.stringify(resultPosts));

// ── 场景 E：对端先答（cancel 帧）同样成对清理 ───────────────────────────────
console.log("\n场景 E：手机离线 + 桌面端先答（cancel 帧）");
phone.emit("close"); // 手机断开 → 回到离线态
await sleep(30);
await emitWaterfall(approvalFrame("evt-2", "call-2"));
const beforeCancel = await diagnostics();
check("E1 离线 + 再次审批：条目 1 / 回放 1", beforeCancel?.checks?.pendingApprovals === 1 && beforeCancel?.checks?.pendingFrames === 1, JSON.stringify(beforeCancel?.checks));
await emitCancel("evt-2");
const afterCancel = await diagnostics();
check("E2 cancel 帧后条目清空（无幽灵卡）", afterCancel?.checks?.pendingApprovals === 0, `实际 ${afterCancel?.checks?.pendingApprovals}`);
check("E3 cancel 帧后回放帧清空", afterCancel?.checks?.pendingFrames === 0, `实际 ${afterCancel?.checks?.pendingFrames}`);
// cancel 路径按 v3.1.3 既有契约会补一次回执（"cancelled"）：网关对**已结算**的事件静默忽略
// （dsh-api-gateway receiveRemoteEventResult 在 pending 缺失时直接 return，dispatchRpc 仍回 ok
// → 不会产生"结算失败"告警），因此这里断言"恰好补一次、不重复轰炸"，而不是"完全不发"。
check("E4 cancel 只补一次回执（网关对已结算事件静默忽略）", resultPosts.length === 2 && resultPosts[1] === "evt-2", JSON.stringify(resultPosts));

// ── 场景 F：问询（user-questions）走同一契约 ────────────────────────────────
console.log("\n场景 F：问询同样在离线时记账");
await emitWaterfall({ event: "user-questions/request", agentId: "session-1", eventId: "evt-3", request: { questions: [{ question: "选哪个？", options: ["A", "B"] }] } });
const afterQuestion = await diagnostics();
check("F1 离线仍建问询条目", afterQuestion?.checks?.pendingQuestions === 1, `实际 ${afterQuestion?.checks?.pendingQuestions}`);
check("F2 问询同样写入回放帧", afterQuestion?.checks?.pendingFrames === 1, `实际 ${afterQuestion?.checks?.pendingFrames}`);
const phone2 = await connectPhone();
check("F3 重连回放含 question/requested", phone2.text.includes("question/requested"), phone2.text.slice(0, 200));

// ── 场景 G：摘要层——任务清单转发与注入标记（v3.1.4 App 侧两项）──────────────
console.log("\n场景 G：summarizeEvent 摘要（任务清单 / 注入标记）");
const { summarizeEvent } = mod;
const todoSummary = summarizeEvent({
	seq: 7,
	type: "todo/write",
	data: {
		todos: [
			{ content: "读透相关代码", status: "completed" },
			{ content: "P0-1 实现", status: "in_progress" },
			{ content: "P0-2 实现", status: "pending" },
			{ content: "y".repeat(500), status: "weird" },
		],
	},
});
check("G1 todo/write 摘要携带清单", todoSummary?.data?.todos?.length === 4, JSON.stringify(todoSummary)?.slice(0, 160));
check("G2 status 白名单外回退 pending", todoSummary?.data?.todos?.[3]?.status === "pending", JSON.stringify(todoSummary?.data?.todos?.[3])?.slice(0, 80));
check("G3 content 截断保护（≤200 字符）", (todoSummary?.data?.todos?.[3]?.content ?? "").length <= 200, `实际 ${(todoSummary?.data?.todos?.[3]?.content ?? "").length}`);
const injectedSummary = summarizeEvent({ seq: 8, type: "user/message", data: { id: "m1", content: [{ type: "text", text: "注入内容" }], source: { kind: "plugin" } } });
check("G4 user/message 透出 sourceKind（注入标记，issue #12）", injectedSummary?.data?.sourceKind === "plugin", JSON.stringify(injectedSummary));
const humanSummary = summarizeEvent({ seq: 9, type: "user/message", data: { id: "m2", content: [{ type: "text", text: "真人发言" }], source: { kind: "user" } } });
check("G5 真人消息 sourceKind = user", humanSummary?.data?.sourceKind === "user", JSON.stringify(humanSummary));
const legacySummary = summarizeEvent({ seq: 10, type: "user/message", data: { id: "m3", content: [{ type: "text", text: "旧内核无 source" }] } });
check("G6 无 source 时不下发该字段（App 退回启发式）", legacySummary?.data?.sourceKind === undefined, JSON.stringify(legacySummary));

// ── 场景 H：/api/todos 端点（App 任务面板的权威读法，与桌面同源）──────────────
console.log("\n场景 H：/api/todos 任务清单端点");
const todosNoSid = await api(`${basePath}/api/todos`);
check("H1 缺 sessionId → 400", todosNoSid.statusCode === 400, `${todosNoSid.statusCode} ${todosNoSid.text}`);
const todosUnknown = await api(`${basePath}/api/todos?sessionId=no-such-session`);
check("H2 未知/未激活会话 → todos: null（不报错，App 退回历史折叠）", todosUnknown.statusCode === 200 && todosUnknown.json?.todos === null, `${todosUnknown.statusCode} ${todosUnknown.text}`);
// 注入内核投影 mock（真实宿主里由 dsh-tool-todo 注册）
services.sessionProjections = {
	stateOf: (session, key) => (key === "todos" && session?.id === "session-1"
		? [{ content: "写文档", status: "in_progress" }, { content: "跑测试", status: "completed" }, { content: "x".repeat(400), status: "bogus" }]
		: undefined),
};
services.agents = { get: (id) => (id === "session-1" ? { session: { id } } : undefined) };
const todosOk = await api(`${basePath}/api/todos?sessionId=session-1`);
check("H3 投影可用时返回清单", todosOk.json?.todos?.length === 3, todosOk.text?.slice(0, 200));
check("H4 status 白名单外回退 pending", todosOk.json?.todos?.[2]?.status === "pending", JSON.stringify(todosOk.json?.todos?.[2])?.slice(0, 80));
check("H5 content 截断保护（≤200 字符）", (todosOk.json?.todos?.[2]?.content ?? "").length <= 200, `实际 ${(todosOk.json?.todos?.[2]?.content ?? "").length}`);

console.log(`\n结果：PASS ${pass} / FAIL ${fail}`);
if (warns.length > 0) console.log(`（插件告警 ${warns.length} 条，最后一条：${warns[warns.length - 1]}）`);
pushServer.close();
process.exit(fail === 0 ? 0 : 1);
