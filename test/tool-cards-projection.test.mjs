/**
 * issue #54（M3 Batch 1）：工具卡结构化投影的单元测试。
 *
 * 覆盖：10 个工具的 `tool/call` summary 字段派生、路径 display（绝不下发绝对路径）、
 * write/edit 的 sizeKb/diff/added/deleted、`tool/result` 的 exitCode/signal/stopped/
 * resultCount（meta 与文本两种来源）、长输出/非法 JSON 的 fail-open、未知工具不投影。
 */
import test from "node:test";
import assert from "node:assert/strict";
import {
	TOOL_CARD_DIFF_MAX_BYTES,
	TOOL_CARD_TOOLS,
	summarizeEvent,
	toolCallSummaryOf,
	toolCardsCapabilityOf,
	toolResultSummaryOf,
} from "../lib/index.js";

const CWD = "/home/mark/proj";
const call = (name, args, cwd = CWD) =>
	summarizeEvent({ seq: 1, type: "tool/call", data: { turn: 1, step: 1, callId: "call-1", name, arguments: typeof args === "string" ? args : JSON.stringify(args) } }, { cwd });
const result = (name, text, meta) =>
	summarizeEvent({
		seq: 2,
		type: "tool/result",
		data: {
			...(name ? { name } : {}),
			message: { content: [{ type: "text", text }] },
			...(meta === undefined ? {} : { meta }),
		},
	});
const summaryOf = (event) => event.data?.summary;

test("能力位：声明本插件实际投影的 10 个工具", () => {
	const caps = toolCardsCapabilityOf();
	assert.equal(caps.version, 1);
	assert.deepEqual(caps.tools, [...TOOL_CARD_TOOLS]);
	assert.deepEqual(TOOL_CARD_TOOLS, ["bash", "pwsh", "read", "write", "edit", "grep", "glob", "web_fetch", "web_search", "read_image"]);
});

test("command：bash/pwsh 的 command/workdir/background/description，换行压平并 clamp", () => {
	const bash = summaryOf(call("bash", { command: "ls\n-la", workdir: "/home/mark/proj/src", run_in_background: true, description: "List\nfiles" }));
	assert.deepEqual(bash, { kind: "command", tool: "bash", command: "ls -la", workdir: "src", background: true, description: "List files" });
	const pwsh = summaryOf(call("pwsh", { command: "Get-ChildItem" }, "C:\\work"));
	assert.equal(pwsh.kind, "command");
	assert.equal(pwsh.command, "Get-ChildItem");
});

test("file/read：filePath display + 正整数 offset/limit（非法忽略）", () => {
	const read = summaryOf(call("read", { file_path: "/home/mark/proj/src/a.ts", offset: 2, limit: 40 }));
	assert.deepEqual(read, { kind: "file", tool: "read", filePath: "src/a.ts", offset: 2, limit: 40 });
	const invalid = summaryOf(call("read", { file_path: "/home/mark/proj/src/a.ts", offset: 0, limit: -3 }));
	assert.equal(invalid.offset, undefined);
	assert.equal(invalid.limit, undefined);
});

test("file/write：sizeKb 按 UTF-16 长度、diff 为全新增统一 diff", () => {
	const content = "第一行\nsecond line\n";
	const write = summaryOf(call("write", { file_path: "src/new.ts", content }));
	assert.equal(write.kind, "file");
	assert.equal(write.filePath, "src/new.ts");
	assert.equal(write.sizeKb, Math.ceil(content.length / 1024));
	assert.equal(write.diff, "--- /dev/null\n+++ b/src/new.ts\n@@ -0,0 +1,2 @@\n+第一行\n+second line\n");
	// 路径必须已派生：summary 里任何字段都不能含主机绝对路径。
	assert.ok(!JSON.stringify(write).includes("/home/mark/proj"));
});

test("file/edit：sizeKb、added/deleted 按行近似、统一 diff", () => {
	const edit = summaryOf(call("edit", { file_path: "src/a.ts", old_string: "a\nb", new_string: "c" }));
	assert.equal(edit.kind, "file");
	assert.equal(edit.filePath, "src/a.ts");
	assert.equal(edit.sizeKb, Math.ceil(("a\nb".length + "c".length) / 1024));
	assert.equal(edit.added, 1);
	assert.equal(edit.deleted, 2);
	assert.equal(edit.diff, "--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,2 +1,1 @@\n-a\n-b\n+c\n");
});

test("write/edit：diff 超过 8 KiB 时缺省并标 diffTruncated", () => {
	const huge = `${"x".repeat(TOOL_CARD_DIFF_MAX_BYTES)}\n`;
	const write = summaryOf(call("write", { file_path: "big.txt", content: huge }));
	assert.equal(write.diff, undefined);
	assert.equal(write.diffTruncated, true);
	const edit = summaryOf(call("edit", { file_path: "big.txt", old_string: huge, new_string: "" }));
	assert.equal(edit.diff, undefined);
	assert.equal(edit.diffTruncated, true);
});

test("search：grep/glob 的 pattern/path/include（clean 参数）", () => {
	const grep = summaryOf(call("grep", { pattern: "foo\nbar", path: "/home/mark/proj/lib", include: "*.ts" }));
	assert.deepEqual(grep, { kind: "search", tool: "grep", pattern: "foo bar", path: "lib", include: "*.ts" });
	const glob = summaryOf(call("glob", { pattern: "**/*.dart", path: "/home/mark/proj/lib" }));
	assert.deepEqual(glob, { kind: "search", tool: "glob", pattern: "**/*.dart", path: "lib" });
	assert.equal(glob.include, undefined);
});

test("web / image：url、query、filePath", () => {
	assert.deepEqual(
		summaryOf(call("web_fetch", { url: "https://example.test/a?b=1" })),
		{ kind: "web", tool: "web_fetch", url: "https://example.test/a?b=1" },
	);
	assert.deepEqual(
		summaryOf(call("web_search", { queries: ["q1", "q2"] })),
		{ kind: "web", tool: "web_search", query: "q1" },
	);
	assert.deepEqual(
		summaryOf(call("read_image", { file_path: "/home/mark/proj/assets/p.png" })),
		{ kind: "image", tool: "read_image", filePath: "assets/p.png" },
	);
});

test("fail-open：非法 JSON / 未知工具 / 非对象参数不抛错且降级", () => {
	assert.deepEqual(summaryOf(call("bash", "{not json")), { kind: "command", tool: "bash" });
	assert.equal(summaryOf(call("mystery", "{}")), undefined);
	assert.equal(toolCallSummaryOf("bash", undefined, CWD)?.kind, "command");
	assert.equal(toolCallSummaryOf(undefined, "{}", CWD), undefined);
});

test("超长参数被 clamp，不影响摘要生成", () => {
	const long = "x".repeat(5000);
	const bash = summaryOf(call("bash", { command: long, description: long }));
	// clampText 把「截断后缀」计入上限：结果长度恰好等于上限。
	assert.equal(bash.command.length, 200);
	assert.equal(bash.description.length, 120);
	const pattern = summaryOf(call("grep", { pattern: long }));
	assert.equal(pattern.pattern.length, 200);
});

test("result：bash/pwsh 从原始文本末尾解析 exitCode/signal/stopped（不受 2000 字 clamp 影响）", () => {
	const longText = `${"x".repeat(3000)}\n[exit code: 7]`;
	const exit = summaryOf(result("bash", longText));
	assert.equal(exit.exitCode, 7);
	assert.equal(result("pwsh", "[killed by signal: SIGTERM]").data.summary.signal, "SIGTERM");
	assert.equal(result("bash", "[stopped: user cancelled]").data.summary.stopped, "user cancelled");
	// 结果事件通常不带工具名：标记解析仍应成立。
	assert.equal(summaryOf(result(undefined, "boom\n[exit code: 2]")).exitCode, 2);
	// 非命令工具文本里的普通数字不会被误判成退出码。
	assert.equal(summaryOf(result("read", "[exit code: 3]")), undefined);
});

test("result：grep/glob 匹配总数优先取 meta.total，缺失时按文本解析，解析不到缺省", () => {
	assert.equal(summaryOf(result("grep", "Found 3 of 9 matches", { shape: "matches", total: 9 })).resultCount, 9);
	assert.equal(summaryOf(result("grep", "Found 3 matches")).resultCount, 3);
	assert.equal(summaryOf(result("grep", "No matches found")).resultCount, 0);
	assert.equal(summaryOf(result("glob", "(Showing 20 of 87 paths...")).resultCount, 87);
	assert.equal(summaryOf(result("glob", "a.ts\nb.ts\nc.ts")).resultCount, 3);
	assert.equal(summaryOf(result("glob", "No files found")).resultCount, 0);
	assert.equal(summaryOf(result(undefined, "garbage text")), undefined);
	assert.equal(summaryOf(result("read", "Found 3 matches")), undefined);
});

test("result：meta 形状可识别搜索工具（结果事件无名字时）", () => {
	assert.equal(summaryOf(result(undefined, "", { shape: "paths", total: 12 })).resultCount, 12);
});
