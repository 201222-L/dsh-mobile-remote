/**
 * issue #68（M3 Batch 2-C）：PTC 子调用事件的服务端结构化投影测试。
 *
 * 覆盖契约（/tmp/issue68-contract.md §1.3-§1.8 / §5.2）：
 * - 能力位 `toolCards.ptc.version === 1`（tools/version 只增不改，键序 version→tools→ptc）；
 * - 真实夹具（test/fixtures/ptc/dispatch-events.json）的 start/result 投影：
 *   `subCallId → callId`、status、summary 紧凑白名单、`text` 仅失败安全错误码（L1）；
 * - 安全：payload 永不含 arguments 原文 / meta / content / images / error.reason / cwd 绝对路径；
 * - fail-open：缺 data / 非法 id / 坏 content / 坏 error 均不抛错；
 * - 50 子调用预算：notice/超限降级、同 callId 去重、跨 root 独立、无 budget 不截断；
 * - turn/step 可选派生（派生不到省略，不伪造 0）；
 * - PTC 事件仍在时间线/实时流、仍无 detail 指针（debug-only 口径不变）。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import {
	TOOL_CARDS_PTC_VERSION,
	TOOL_CARD_TOOLS,
	createPtcBudget,
	isDetailVisibleType,
	isLiveTimelineRecord,
	isTimelineRecord,
	ptcGateOf,
	summarizeEvent,
	toolCardsCapabilityOf,
} from "../lib/index.js";

const readJson = (name) => JSON.parse(readFileSync(new URL(`./fixtures/ptc/${name}`, import.meta.url), "utf8"));
const DISPATCH_FIXTURE = readJson("dispatch-events.json");
const OUTER_FIXTURE = readJson("outer-tool-events.json");
/** 测试用合成 cwd（沿用仓库既有测试惯例）；夹具里的真实工作目录已脱敏为 <workspace>，
 *  这里验证投影绝不携带 cwd 绝对路径。 */
const CWD = "/home/mark/proj";
const OUTER_CALL_ID = DISPATCH_FIXTURE.capture.outerCallId;
/** 夹具里按类型 + subCallId 取事件，避免硬编码 seq 顺序（捕获时 bash result 被 job 事件隔开）。 */
const fixtureEvent = (type, subCallSuffix) =>
	DISPATCH_FIXTURE.events.find((event) => event.type === type && event.data.subCallId === `${OUTER_CALL_ID}:ptc:${subCallSuffix}`);
const summarize = (event, options = {}) => summarizeEvent(event, { cwd: CWD, ...options });
const dataOf = (event, options = {}) => summarize(event, options).data;

/** 合成一条 PTC 事件（默认 start；wire data 与内核契约一致）。 */
const ptcEvent = (data, { type = "tool/ptc-dispatch-start", seq = 1, time } = {}) => ({
	seq,
	...(time === undefined ? {} : { time }),
	type,
	data,
});
const startOf = (callId, extra = {}) =>
	ptcEvent({ rootCallId: "root-1", parentCallId: "root-1", subCallId: callId, name: "read", arguments: { file_path: "README.md" }, ...extra });
const resultOf = (callId, extra = {}) =>
	ptcEvent(
		{ rootCallId: "root-1", parentCallId: "root-1", subCallId: callId, name: "read", arguments: { file_path: "README.md" }, isError: false, content: [{ type: "text", text: "ok" }], ...extra },
		{ type: "tool/ptc-dispatch", seq: 100 },
	);

test("能力位：toolCards.ptc.version=1，tools/version 只增不改且键序 version→tools→ptc", () => {
	const caps = toolCardsCapabilityOf();
	assert.equal(TOOL_CARDS_PTC_VERSION, 1);
	assert.equal(caps.version, 1);
	assert.deepEqual(caps.tools, [...TOOL_CARD_TOOLS]);
	assert.deepEqual(caps.ptc, { version: 1 });
	// 既有 contract 断言依赖 `"toolCards":{"version":1,"tools":` 前缀；ptc 必须在 tools 之后。
	const json = JSON.stringify(caps);
	assert.ok(json.startsWith('{"version":1,"tools":['), json);
	assert.ok(json.indexOf('"ptc"') > json.indexOf('"tools"'), json);
});

test("真实夹具 fail-open：data 缺失/非对象、id 缺失/空/超长 → {seq,type} 无 data 且不抛错", () => {
	const badEvents = [
		{ seq: 1, type: "tool/ptc-dispatch" },
		{ seq: 2, type: "tool/ptc-dispatch-start", data: null },
		{ seq: 3, type: "tool/ptc-dispatch-start", data: "x" },
		{ seq: 4, type: "tool/ptc-dispatch-start", data: [] },
		{ seq: 5, type: "tool/ptc-dispatch-start", data: {} },
		{ seq: 6, type: "tool/ptc-dispatch-start", data: { parentCallId: "p" } },
		{ seq: 7, type: "tool/ptc-dispatch-start", data: { subCallId: "c" } },
		{ seq: 8, type: "tool/ptc-dispatch-start", data: { subCallId: "", parentCallId: "p" } },
		{ seq: 9, type: "tool/ptc-dispatch-start", data: { subCallId: "c", parentCallId: "" } },
		{ seq: 10, type: "tool/ptc-dispatch-start", data: { subCallId: "x".repeat(301), parentCallId: "p" } },
		{ seq: 11, type: "tool/ptc-dispatch-start", data: { subCallId: "c", parentCallId: "p".repeat(301) } },
	];
	for (const event of badEvents) {
		const summary = summarize(event);
		assert.equal(summary.seq, event.seq);
		assert.equal(summary.type, event.type);
		assert.equal(summary.data, undefined, JSON.stringify(event));
	}
	// 坏 content / 坏 error 不影响投影（content 完全不参与投影，不抛错）。
	const failed = dataOf(resultOf("c-bad", { isError: true, content: "not-an-array", error: { name: "E", code: "C" } }));
	assert.equal(failed.status, "failed");
	assert.equal(failed.text, "C");
	assert.deepEqual(failed.error, { name: "E", code: "C" });
	const nullError = dataOf(resultOf("c-null-error", { isError: true, content: null, error: null }));
	assert.equal(nullError.status, "failed");
	assert.equal(nullError.text, undefined);
	assert.equal(nullError.error, undefined);
});

test("真实夹具 start 投影：subCallId→callId、status=running、summary 白名单字段，且无 text/isError/error/arguments/meta", () => {
	const readStart = dataOf(fixtureEvent("tool/ptc-dispatch-start", 1));
	assert.deepEqual(readStart, {
		rootCallId: OUTER_CALL_ID,
		parentCallId: OUTER_CALL_ID,
		callId: `${OUTER_CALL_ID}:ptc:1`,
		name: "read",
		status: "running",
		summary: { kind: "file", tool: "read", filePath: "README.md", limit: 3 },
	});

	const bashStart = dataOf(fixtureEvent("tool/ptc-dispatch-start", 2));
	assert.equal(bashStart.status, "running");
	assert.equal(bashStart.callId, `${OUTER_CALL_ID}:ptc:2`);
	assert.deepEqual(bashStart.summary, {
		kind: "command",
		tool: "bash",
		command: "echo ptc-fixture-ok",
		description: "Print the fixture marker",
	});

	for (const event of DISPATCH_FIXTURE.events) {
		const data = dataOf(event);
		for (const forbidden of ["arguments", "meta", "content", "images", "isError", "error", "text"]) {
			if (event.type === "tool/ptc-dispatch-start") assert.equal(data[forbidden], undefined, `${event.type} must not expose ${forbidden}`);
		}
		assert.equal(data.subCallId, undefined, "wire 字段名是 callId，不是 subCallId");
	}
});

test("真实夹具 result 成功：status=success、isError=false 显式存在、无 text/error，且不携带 meta/content", () => {
	const readResult = fixtureEvent("tool/ptc-dispatch", 1);
	const data = dataOf(readResult);
	assert.equal(data.status, "success");
	assert.equal(data.isError, false);
	assert.equal(data.text, undefined);
	assert.equal(data.error, undefined);
	assert.equal(data.meta, undefined);
	assert.equal(data.content, undefined);
	// bash 成功事件的 meta.cwd 被丢弃（不泄露 <workspace> 路径）。
	const bashResult = fixtureEvent("tool/ptc-dispatch", 2);
	const bashData = dataOf(bashResult);
	assert.equal(bashData.status, "success");
	assert.equal(bashData.meta, undefined);
	assert.equal(JSON.stringify(bashData).includes(CWD), false);
	assert.equal(JSON.stringify(bashData).includes("<workspace>"), false);
});

test("真实夹具 result 失败（L1）：text=error.code 安全错误码、error 仅 {name,code}、绝不含 content 原文/路径", () => {
	const data = dataOf(fixtureEvent("tool/ptc-dispatch", 3));
	assert.equal(data.status, "failed");
	assert.equal(data.isError, true);
	assert.equal(data.text, "FS_NOT_FOUND");
	assert.deepEqual(data.error, { name: "FsError", code: "FS_NOT_FOUND" });
	assert.equal(data.error.reason, undefined);
	const json = JSON.stringify(data);
	assert.equal(json.includes("cannot read"), false, json);
	assert.equal(json.includes(CWD), false, json);
	assert.equal(json.includes("<workspace>"), false, json);
	assert.equal(json.includes("content"), false, json);
});

test("失败 text 白名单：code 优先、fallback name、两者皆缺省略；各 clamp ≤120/≤500，不取 content", () => {
	const contentWithSecret = [{ type: "text", text: `Error: cannot read "${CWD}/secret.txt"` }];
	assert.deepEqual(
		(function () {
			const data = dataOf(resultOf("c-code", { isError: true, error: { name: "SomeError", code: "CODE_A", reason: `${CWD}/reason` }, content: contentWithSecret }));
			return [data.text, data.error];
		})(),
		["CODE_A", { name: "SomeError", code: "CODE_A" }],
	);
	// 只有 name：text 用 name，error 需要 name+code 两者才下发。
	const onlyName = dataOf(resultOf("c-name", { isError: true, error: { name: "OnlyName" } }));
	assert.equal(onlyName.text, "OnlyName");
	assert.equal(onlyName.error, undefined);
	// 只有 code：text 用 code。
	const onlyCode = dataOf(resultOf("c-code-only", { isError: true, error: { code: "ONLY_CODE" } }));
	assert.equal(onlyCode.text, "ONLY_CODE");
	assert.equal(onlyCode.error, undefined);
	// 两者皆缺：省略 text 与 error。
	const neither = dataOf(resultOf("c-neither", { isError: true, error: {} }));
	assert.equal(neither.text, undefined);
	assert.equal(neither.error, undefined);
	// L2-2：超长/含非法字符的错误码不是安全 token → 不回退原文；text 退到合法 name，error 省略。
	const longCode = "X".repeat(600);
	const invalidLong = dataOf(resultOf("c-long", { isError: true, error: { name: "E", code: longCode } }));
	assert.equal(invalidLong.text, "E");
	assert.equal(invalidLong.error, undefined);
	assert.equal(invalidLong.text.includes("X"), false);
	// 安全码语法上界（64 字符）内的长码仍可下发，且 clamp ≤120/≤500。
	const safeLong = `E${"X".repeat(60)}`;
	const longButSafe = dataOf(resultOf("c-safe-long", { isError: true, error: { name: "E", code: safeLong } }));
	assert.equal(longButSafe.text, safeLong);
	assert.deepEqual(longButSafe.error, { name: "E", code: safeLong });
});

test("L2-2 安全码语法：自由文本/路径/注入字符的错误码一律省略，合法码正常下发", () => {
	const evil = dataOf(resultOf("c-evil", { isError: true, error: { name: "Evil<script>", code: "/home/x/secret" } }));
	assert.equal(evil.status, "failed");
	assert.equal(evil.isError, true);
	assert.equal(evil.text, undefined);
	assert.equal(evil.error, undefined);
	assert.equal(JSON.stringify(evil).includes("/home/"), false);
	const spaces = dataOf(resultOf("c-space", { isError: true, error: { name: "bad name", code: "bad code" } }));
	assert.equal(spaces.text, undefined);
	assert.equal(spaces.error, undefined);
	// name 合法、code 非法：text 可用 name（安全 token），error 需要两者都合法 → 省略。
	const mixed = dataOf(resultOf("c-mixed", { isError: true, error: { name: "FsError", code: "/home/x/secret" } }));
	assert.equal(mixed.text, "FsError");
	assert.equal(mixed.error, undefined);
});

test("L2-1 summary 自由文本脱敏：command/description 的主机路径不出 payload，URL 保持原样", () => {
	const scrubSummary = (args) => dataOf(ptcEvent({
		rootCallId: "root-1",
		parentCallId: "root-1",
		subCallId: "c-scrub",
		name: "bash",
		arguments: args,
	})).summary;
	const otherHome = scrubSummary({ command: "cat /home/other-user/private/secret.txt" });
	assert.equal(otherHome.command, "cat …/secret.txt");
	assert.equal(otherHome.command.includes("/home/"), false);
	assert.equal(otherHome.command.includes("other-user"), false);
	// cwd 内绝对路径 → 相对（cwd 前缀替换为 .）。
	const insideCwd = scrubSummary({ command: `cat ${CWD}/src/a.ts` });
	assert.equal(insideCwd.command, "cat ./src/a.ts");
	// homedir 前缀 → ~（不是绝对路径形态）。
	const home = scrubSummary({ command: `cat ${homedir()}/private/x.txt` });
	assert.equal(home.command, "cat ~/private/x.txt");
	assert.equal(home.command.includes(homedir()), false);
	// URL 不得被错误改写；同串里的其它绝对路径仍脱敏。
	const withUrl = scrubSummary({ command: "curl https://example.com/a/b?x=1 && cat /etc/passwd" });
	assert.equal(withUrl.command, "curl https://example.com/a/b?x=1 && cat …/passwd");
	// Windows / file:/// 绝对路径同样只保留 basename。
	assert.equal(scrubSummary({ command: "cat C:\\Users\\secret\\a.txt" }).command, "cat …/a.txt");
	assert.equal(scrubSummary({ command: "cat file:///home/x/a.txt" }).command, "cat …/a.txt");
	// description 也脱敏；结构字段（filePath）保持 mobileDisplayPath 相对形态。
	const withDescription = dataOf(ptcEvent({
		rootCallId: "root-1",
		parentCallId: "root-1",
		subCallId: "c-desc",
		name: "read",
		arguments: { file_path: `${CWD}/README.md`, limit: 3 },
		description: "read /home/other-user/private/secret.txt",
	}));
	assert.equal(withDescription.summary.filePath, "README.md");
	assert.equal(JSON.stringify(withDescription).includes("/home/"), false);
});

test("L2-3/L2-4 notice 不带 turn/step；drop 无 data 但保留通用顶层 time", () => {
	const budget = createPtcBudget();
	const root = "root-l2";
	for (let index = 1; index <= 50; index++) {
		ptcGateOf(budget, { rootCallId: root, subCallId: `l2-${index}` });
	}
	const notice = summarize(
		{ seq: 300, time: 1794286650000, type: "tool/ptc-dispatch-start", data: { rootCallId: root, parentCallId: root, subCallId: "l2-51", name: "read" } },
		{ turn: 3, step: 2, ptcBudget: budget },
	);
	assert.equal(notice.data.truncated, true);
	for (const forbidden of ["turn", "step", "summary", "text", "isError", "error"]) {
		assert.equal(notice.data[forbidden], undefined, forbidden);
	}
	// 第 51 个的 result → drop：无 data，time 保留。
	const droppedResult = summarize(
		{ seq: 301, time: 1794286650001, type: "tool/ptc-dispatch", data: { rootCallId: root, parentCallId: root, subCallId: "l2-51", name: "read", isError: false, content: [{ type: "text", text: "ok" }] } },
		{ turn: 3, step: 2, ptcBudget: budget },
	);
	assert.equal(droppedResult.data, undefined);
	assert.equal(droppedResult.seq, 301);
	assert.equal(droppedResult.type, "tool/ptc-dispatch");
	assert.equal(droppedResult.time, 1794286650001);
	// 第 52 个 start 同样 drop 无 data。
	const droppedStart = summarize(
		{ seq: 302, time: 1794286650002, type: "tool/ptc-dispatch-start", data: { rootCallId: root, parentCallId: root, subCallId: "l2-52", name: "read" } },
		{ turn: 3, step: 2, ptcBudget: budget },
	);
	assert.equal(droppedStart.data, undefined);
	assert.equal(droppedStart.time, 1794286650002);
});

test("summary 安全：路径一律 display（cwd 内绝对路径→相对）、write 正文/etc 不进摘要、image 不带 relative/previewable", () => {
	const absoluteRead = dataOf(ptcEvent({
		rootCallId: "root-1",
		parentCallId: "root-1",
		subCallId: "c-abs",
		name: "read",
		arguments: { file_path: `${CWD}/README.md`, limit: 3 },
	}));
	assert.equal(absoluteRead.summary.filePath, "README.md");
	assert.equal(JSON.stringify(absoluteRead).includes(CWD), false);

	const writeStart = dataOf(ptcEvent({
		rootCallId: "root-1",
		parentCallId: "root-1",
		subCallId: "c-write",
		name: "write",
		arguments: { file_path: "secret.txt", content: "SECRET_CONTENT_XYZ" },
	}));
	assert.equal(JSON.stringify(writeStart.summary).includes("SECRET_CONTENT_XYZ"), false);
	assert.equal(writeStart.summary.filePath, "secret.txt");
	assert.equal(writeStart.summary.sizeKb, 1);

	const imageStart = dataOf(ptcEvent({
		rootCallId: "root-1",
		parentCallId: "root-1",
		subCallId: "c-image",
		name: "read_image",
		arguments: { file_path: "shot.png" },
	}));
	assert.deepEqual(imageStart.summary, { kind: "image", tool: "read_image", filePath: "shot.png" });

	// 未知工具：无 summary（App 只显示名称+状态），其余字段仍下发。
	const unknownStart = dataOf(ptcEvent({ rootCallId: "root-1", parentCallId: "root-1", subCallId: "c-unknown", name: "custom_tool", arguments: { x: 1 } }));
	assert.equal(unknownStart.summary, undefined);
	assert.equal(unknownStart.status, "running");
	assert.equal(unknownStart.name, "custom_tool");
});

test("summary 2KiB 预算：超限整份降级为 {kind,tool}，正常摘要保留", () => {
	const todos = Array.from({ length: 50 }, (_, index) => ({ content: `${"x".repeat(200)}${index}`, status: "pending" }));
	const oversized = dataOf(ptcEvent({
		rootCallId: "root-1",
		parentCallId: "root-1",
		subCallId: "c-todo",
		name: "todo_write",
		arguments: { todos },
	}));
	assert.deepEqual(oversized.summary, { kind: "todo", tool: "todo_write" });
	const normal = dataOf(startOf("c-small", { arguments: { file_path: "a.txt", limit: 5 } }));
	assert.deepEqual(normal.summary, { kind: "file", tool: "read", filePath: "a.txt", limit: 5 });
});

test("name/id clamp 与 turn/step 可选派生：非法位置省略，不伪造 0", () => {
	const minimal = dataOf(ptcEvent({ rootCallId: "root-1", parentCallId: "root-1", subCallId: "c-min", name: "", arguments: 42 }));
	assert.equal(minimal.name, undefined);
	assert.equal(minimal.summary, undefined);

	const longName = dataOf(ptcEvent({ rootCallId: "root-1", parentCallId: "root-1", subCallId: "c-name", name: "n".repeat(200) }));
	assert.ok(longName.name.length <= 120, String(longName.name.length));

	assert.deepEqual(
		(() => {
			const data = dataOf(startOf("c-loc"), { turn: 3, step: 2 });
			return [data.turn, data.step];
		})(),
		[3, 2],
	);
	assert.equal(dataOf(startOf("c-loc2"), { turn: 0, step: -1 }).turn, undefined);
	assert.equal(dataOf(startOf("c-loc2"), { turn: 0, step: -1 }).step, undefined);
	assert.equal(dataOf(startOf("c-loc3"), { turn: "3", step: 1.5 }).turn, undefined);
	assert.equal(dataOf(startOf("c-loc4")).turn, undefined);
	assert.equal(dataOf(startOf("c-loc4")).step, undefined);
});

test("50 上限：前 50 个 callId 全量、第 51 个只发最小 truncated notice、其后降级；同 callId 去重、跨 root 独立", () => {
	const budget = createPtcBudget();
	const rootA = "root-A";
	const rootB = "root-B";
	const eventOf = (root, callId, seq) => ptcEvent({ rootCallId: root, parentCallId: root, subCallId: callId, name: "read", arguments: { file_path: "f" } }, { seq });
	// 50 个唯一 callId：全部 full。
	for (let index = 1; index <= 50; index++) {
		const data = dataOf(eventOf(rootA, `a-${index}`, index), { ptcBudget: budget });
		assert.equal(data.callId, `a-${index}`);
		assert.equal(data.truncated, undefined);
	}
	// 重复的 start 不占新名额。
	assert.equal(dataOf(eventOf(rootA, "a-1", 60), { ptcBudget: budget }).callId, "a-1");
	// 第 51 个 callId：start 是 notice；同 callId 的 result 被 drop 成 {seq,type}。
	const notice = summarize(eventOf(rootA, "a-51", 61), { ptcBudget: budget });
	assert.equal(notice.data.truncated, true);
	assert.equal(notice.data.callId, "a-51");
	assert.equal(notice.data.status, "running");
	for (const forbidden of ["summary", "text", "isError", "error", "turn", "step"]) assert.equal(notice.data[forbidden], undefined, forbidden);
	const dropped = summarize(resultOf("a-51", { rootCallId: rootA, parentCallId: rootA }), { ptcBudget: budget });
	assert.deepEqual(dropped, { seq: 100, type: "tool/ptc-dispatch" });
	// 已计数子调用在 notice 之后到达的 result 仍全量。
	const lateResult = dataOf(resultOf("a-7", { rootCallId: rootA, parentCallId: rootA }), { ptcBudget: budget });
	assert.equal(lateResult.status, "success");
	assert.equal(lateResult.isError, false);
	// 另一个 root 有独立 50 名额。
	assert.equal(dataOf(eventOf(rootB, "b-1", 62), { ptcBudget: budget }).callId, "b-1");
	// 无 budget（纯函数模式）不截断。
	for (let index = 51; index <= 60; index++) {
		assert.equal(dataOf(eventOf(rootA, `a-${index}`, 100 + index)).callId, `a-${index}`);
	}
});

test("ptcGateOf：无 budget/坏 budget → full；同一 root 只发一条 notice", () => {
	assert.equal(ptcGateOf(undefined, { rootCallId: "r", subCallId: "c" }), "full");
	assert.equal(ptcGateOf({}, { rootCallId: "r", subCallId: "c" }), "full");
	const budget = createPtcBudget();
	for (let index = 1; index <= 50; index++) ptcGateOf(budget, { rootCallId: "r", subCallId: `c-${index}` });
	assert.equal(ptcGateOf(budget, { rootCallId: "r", subCallId: "c-51" }), "notice");
	assert.equal(ptcGateOf(budget, { rootCallId: "r", subCallId: "c-52" }), "drop");
	assert.equal(ptcGateOf(budget, { rootCallId: "r", subCallId: "c-51" }), "drop");
	// rootCallId 缺省时归入空串 root，与显式 root 互不影响。
	const noRootBudget = createPtcBudget();
	for (let index = 1; index <= 50; index++) ptcGateOf(noRootBudget, { subCallId: `n-${index}` });
	assert.equal(ptcGateOf(noRootBudget, { subCallId: "n-51" }), "notice");
});

test("事件保真/debug-only 口径不变：PTC 事件仍进历史与实时流、仍无 detail 指针、不被 REPLAY 过滤", () => {
	for (const type of ["tool/ptc-dispatch-start", "tool/ptc-dispatch"]) {
		const event = { seq: 1, type, data: { subCallId: "c", parentCallId: "p" } };
		assert.equal(isTimelineRecord(event), true, type);
		assert.equal(isLiveTimelineRecord(event), true, type);
		assert.equal(isDetailVisibleType(type), false, type);
		const summary = summarize(event);
		assert.equal(summary.detail, undefined, type);
		assert.equal(summary.data.parentCallId, "p");
	}
	// 未知事件摘要行为不变（default 分支）。
	assert.deepEqual(summarizeEvent({ seq: 3, type: "future/visible", data: { secretLike: "raw" } }), { seq: 3, type: "future/visible" });
	// 旧字段：tool/call 仍保留 arguments/summary，tool/result 仍保留 text。
	const call = summarizeEvent({ seq: 4, type: "tool/call", data: { turn: 1, step: 1, callId: "call-1", name: "bash", arguments: { command: "ls" } } });
	assert.equal(call.data.arguments, '{"command":"ls"}');
	assert.equal(call.data.summary.tool, "bash");
	const result = summarizeEvent({ seq: 5, type: "tool/result", data: { turn: 1, step: 1, message: { content: [{ type: "text", text: "done" }] }, name: "bash" } });
	assert.equal(result.data.text, "done");
	assert.equal(result.data.isError, false);
});

test("夹具自身一致性：outer toolCallId 与 PTC rootCallId 一致，可被 App 挂到根工具卡", () => {
	const outerCall = OUTER_FIXTURE.events.find((event) => event.type === "tool/call");
	const outerResult = OUTER_FIXTURE.events.find((event) => event.type === "tool/result");
	assert.equal(outerCall.data.callId, OUTER_CALL_ID);
	assert.equal(outerResult.data.message.toolCallId, OUTER_CALL_ID);
	for (const event of DISPATCH_FIXTURE.events) {
		assert.equal(event.data.rootCallId, OUTER_CALL_ID);
		assert.equal(event.data.parentCallId, OUTER_CALL_ID);
	}
});
