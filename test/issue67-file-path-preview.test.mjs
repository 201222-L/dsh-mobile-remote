/**
 * issue #67（M3 Batch 2-B）：工具卡路径可点预览的**服务端边界矩阵**。
 *
 * 全部用例使用真实临时目录（mkdtemp + writeFileSync + symlinkSync），不 mock fs：
 * 契约要求排序本身即安全边界（词法校验 → cwd realpath → 候选 realpath containment），
 * mock 掉 fs 只会测到假顺序。覆盖见 /tmp/issue67-contract.md §1.3 / §3.1。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
	chmodSync,
	mkdirSync,
	mkdtempSync,
	realpathSync,
	rmSync,
	symlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	TOOL_CARD_PREVIEW_PATH_MAX,
	previewTargetOf,
	summarizeEvent,
} from "../lib/index.js";

/** 真实临时工作目录；cwd 一律用 realpath（/tmp 在个别平台是软链）。 */
function workspace(t) {
	const root = realpathSync(mkdtempSync(join(tmpdir(), "issue67-preview-")));
	t.after(() => rmSync(root, { recursive: true, force: true }));
	return root;
}

/** 在 root 下写文件（自动建父目录）。 */
function putFile(root, relative, content = "x\n") {
	const target = join(root, relative);
	mkdirSync(join(target, ".."), { recursive: true });
	writeFileSync(target, content);
	return target;
}

const call = (name, args, cwd) =>
	summarizeEvent(
		{
			seq: 1,
			type: "tool/call",
			data: {
				turn: 1,
				step: 1,
				callId: "call-1",
				name,
				arguments: typeof args === "string" ? args : JSON.stringify(args),
			},
		},
		cwd === undefined ? {} : { cwd },
	).data?.summary;

const read = (path, cwd) => call("read", { file_path: path }, cwd);

/** 断言不可预览：两字段**一起**缺省（不发 previewable:false）。 */
function assertNotPreviewable(summary, message) {
	assert.ok(summary, "summary 不应整段缺失");
	assert.equal(summary.relative, undefined, message ?? "relative 必须缺省");
	assert.equal(summary.previewable, undefined, message ?? "previewable 必须缺省");
	assert.ok(!("relative" in summary));
	assert.ok(!("previewable" in summary));
}

/** 断言可预览且 payload 不含绝对路径。 */
function assertPreviewable(summary, expectedRelative, root) {
	assert.equal(summary.relative, expectedRelative);
	assert.equal(summary.previewable, true);
	assert.ok(!summary.relative.startsWith("/"), "relative 不得以 / 开头");
	assert.ok(!/^[A-Za-z]:/.test(summary.relative), "relative 不得含盘符");
	assert.ok(!summary.relative.includes("\\"), "relative 必须是 POSIX 分隔");
	assert.ok(
		!JSON.stringify(summary).includes(root),
		"摘要 payload 不得出现 cwd 绝对路径",
	);
}

test("cwd 内相对普通文件：relative + previewable:true，payload 无绝对路径", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	const summary = read("src/a.ts", root);
	assertPreviewable(summary, "src/a.ts", root);
	assert.equal(summary.filePath, "src/a.ts");
	assert.equal(summary.kind, "file");
	assert.equal(summary.tool, "read");
});

test("cwd 内绝对路径：换算成同一 relative（D1）", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	const absolute = join(root, "src/a.ts");
	const fromRelative = read("src/a.ts", root);
	const fromAbsolute = read(absolute, root);
	assertPreviewable(fromAbsolute, "src/a.ts", root);
	assert.deepEqual(fromAbsolute, fromRelative, "相对/绝对输入必须得到同一摘要");
});

test("cwd 外绝对路径：两字段皆缺，摘要只剩 display（零探测路径）", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	// /etc/passwd 一定存在且可读；词法就判 cwd 外，必须在任何 fs 探测之前返回。
	const summary = read("/etc/passwd", root);
	assertNotPreviewable(summary, "/etc/passwd 不得可预览");
	assert.deepEqual(summary, { kind: "file", tool: "read", filePath: "passwd" });
	assert.ok(!JSON.stringify(summary).includes(root));
});

test(".. 逃逸 / 中间 .. / 前置 ./ / 空段：词法拒绝；单次 ./ 归一", (t) => {
	const root = workspace(t);
	mkdirSync(join(root, "src"));
	putFile(root, "a.ts");
	putFile(root, "src/b.ts");
	const bad = ["../x", "src/../../x", "a/../b", "src/./b.ts", "a//b", "a/", "././a.ts", "/", "//x"];
	for (const path of bad) {
		assertNotPreviewable(read(path, root), `${JSON.stringify(path)} 必须拒绝`);
	}
	// 只剥一次前导 `./`（与 display 的 /^\.\// 同式）。
	assertPreviewable(read("./a.ts", root), "a.ts", root);
});

test("盘符 / UNC / 反斜杠：绝对形态拒绝，相对反斜杠按归一后判定", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	for (const path of ["C:\\x", "C:\\Windows\\system32", "\\\\server\\share\\x", "//server/share/x"]) {
		assertNotPreviewable(read(path, root), `${JSON.stringify(path)} 必须拒绝`);
	}
	// POSIX 宿主上 `src\a.ts` 是合法文件名；归一后是存在的 src/a.ts → 可预览。
	assertPreviewable(read("src\\a.ts", root), "src/a.ts", root);
});

test("目录 / 缺失 / FIFO：存在但不是普通文件 → 缺省", (t) => {
	const root = workspace(t);
	mkdirSync(join(root, "src"));
	putFile(root, "src/a.ts");
	assertNotPreviewable(read("src", root), "目录不可预览");
	assertNotPreviewable(read("nope.ts", root), "缺失文件不可预览");
	const fifo = join(root, "pipe");
	execFileSync("mkfifo", [fifo]);
	assertNotPreviewable(read("pipe", root), "FIFO 不可预览（防 /files 阻塞读）");
});

test("符号链接逃逸 cwd → 拒绝；符号链接指回 cwd 内 → 允许且 relative 是词法路径", (t) => {
	const root = workspace(t);
	const outside = workspace(t);
	putFile(outside, "secret.txt");
	symlinkSync(outside, join(root, "escape"));
	putFile(root, "real/inner.txt");
	symlinkSync(join(root, "real"), join(root, "alias"));

	assertNotPreviewable(read("escape/secret.txt", root), "符号链接逃逸必须拒绝");
	// 目标仍在 cwd 内：允许，且 relative 保留用户路径的词法形状（alias/… 而非 real/…）。
	const inside = read("alias/inner.txt", root);
	assertPreviewable(inside, "alias/inner.txt", root);
});

test("cwd 缺失/非法：fail-closed（无 fs 探测）", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	const fileCwd = join(root, "src/a.ts");
	for (const cwd of [undefined, "", 42, null, {}, "relative/dir", join(root, "missing-dir"), fileCwd]) {
		const summary = read("src/a.ts", cwd);
		assertNotPreviewable(summary, `cwd=${JSON.stringify(cwd)} 必须 fail-closed`);
	}
});

test("空格 / Unicode 文件名：relative 原样", (t) => {
	const root = workspace(t);
	putFile(root, "a b/中文.md");
	assertPreviewable(read("a b/中文.md", root), "a b/中文.md", root);
});

test("嵌套多段路径：relative 原样", (t) => {
	const root = workspace(t);
	putFile(root, "a/b/c/d.ts");
	assertPreviewable(read("a/b/c/d.ts", root), "a/b/c/d.ts", root);
});

test("relative 长度边界：=300 允许，>300 整段缺省（绝不截断）", (t) => {
	const root = workspace(t);
	const dir = "d".repeat(200);
	const exactly = "f".repeat(TOOL_CARD_PREVIEW_PATH_MAX - 201); // 200 + '/' + 99 = 300
	putFile(root, `${dir}/${exactly}`);
	const ok = read(`${dir}/${exactly}`, root);
	assertPreviewable(ok, `${dir}/${exactly}`, root);
	assert.equal(ok.relative.length, 300);

	const tooLong = "f".repeat(TOOL_CARD_PREVIEW_PATH_MAX - 200); // 200 + '/' + 100 = 301
	putFile(root, `${dir}/${tooLong}`);
	const rejected = read(`${dir}/${tooLong}`, root);
	assertNotPreviewable(rejected, ">300 必须整段缺省");
	// 不截断：`relative` 键必须整个缺省（截断成 300 字会指向另一个文件）；
	// `filePath` 的 300 字 clamp 是既有 display 口径，与本字段无关。
	assert.ok(!("relative" in rejected));
});

test("NUL / 首尾空白 / 非字符串 / 超长原始串：拒绝", (t) => {
	const root = workspace(t);
	putFile(root, "a.ts");
	const cases = [
		"a\0b",
		" a.ts",
		"a.ts ",
		"a.ts\n",
		42,
		true,
		{ path: "a.ts" },
		"a".repeat(4097),
	];
	for (const path of cases) {
		assertNotPreviewable(read(path, root), `${JSON.stringify(path)} 必须拒绝`);
	}
});

test("非文件工具（bash/workdir、grep/path、glob/path）不产生 relative/previewable", (t) => {
	const root = workspace(t);
	mkdirSync(join(root, "src"));
	const bash = call("bash", { command: "ls", workdir: "src" }, root);
	assert.equal(bash.workdir, "src");
	assertNotPreviewable(bash, "bash/workdir 不扩到可预览");
	// 即便伪造 file_path，非四工具也不下发（不因参数形状扩大能力）。
	const grep = call("grep", { pattern: "foo", path: "src", file_path: "src" }, root);
	assert.equal(grep.path, "src");
	assertNotPreviewable(grep, "grep/path 不扩到可预览");
	const glob = call("glob", { pattern: "**/*.ts", path: "src" }, root);
	assertNotPreviewable(glob, "glob/path 不扩到可预览");
});

test("旧字段逐字节不变：删掉两个新字段后与 #54 期望对象 deepEqual", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	const summary = read("src/a.ts", root);
	assertPreviewable(summary, "src/a.ts", root);
	// 新字段只增不改：删除后必须与旧契约对象逐键一致。
	const legacy = { ...summary };
	delete legacy.relative;
	delete legacy.previewable;
	assert.deepEqual(legacy, {
		kind: "file",
		tool: "read",
		filePath: "src/a.ts",
	});
	// write/edit 带 diff/统计的旧字段同样不变。
	putFile(root, "src/b.ts", "old\n");
	const write = call("write", { file_path: "src/b.ts", content: "new\n" }, root);
	delete write.relative;
	delete write.previewable;
	assert.deepEqual(write, {
		kind: "file",
		tool: "write",
		filePath: "src/b.ts",
		sizeKb: 1,
		diff: "--- /dev/null\n+++ b/src/b.ts\n@@ -0,0 +1,1 @@\n+new\n",
	});
});

test("read/write/edit/read_image 四个工具都挂同一组字段", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts", "old\n");
	putFile(root, "photo.png", Buffer.from([0x89, 0x50, 0x4e, 0x47]));
	const cases = [
		["read", { file_path: "src/a.ts" }, "src/a.ts"],
		["write", { file_path: "src/a.ts", content: "new\n" }, "src/a.ts"],
		["edit", { file_path: "src/a.ts", old_string: "old", new_string: "new" }, "src/a.ts"],
		["read_image", { file_path: "photo.png" }, "photo.png"],
		// camelCase 变体同样接受（read_image 旧宿主可能用 filePath）。
		["read_image", { filePath: "photo.png" }, "photo.png"],
	];
	for (const [tool, args, expected] of cases) {
		const summary = call(tool, args, root);
		assertPreviewable(summary, expected, root);
	}
});

test("不可读文件 → 缺省（root 环境无法构造 000 权限，跳过）", { skip: process.getuid?.() === 0 }, (t) => {
	const root = workspace(t);
	const target = putFile(root, "secret.txt");
	chmodSync(target, 0o000);
	try {
		assertNotPreviewable(read("secret.txt", root), "不可读文件必须缺省");
	} finally {
		chmodSync(target, 0o600);
	}
});

test("write 新文件：执行前缺省、落盘后可预览（存在性口径 D5）", (t) => {
	const root = workspace(t);
	const before = call("write", { file_path: "new.ts", content: "x\n" }, root);
	assertNotPreviewable(before, "执行前的 write 摘要目标尚不存在");
	writeFileSync(join(root, "new.ts"), "x\n");
	const after = call("write", { file_path: "new.ts", content: "x\n" }, root);
	assertPreviewable(after, "new.ts", root);
});

test("previewTargetOf 直接契约：成功对象只有两个键", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	assert.deepEqual(previewTargetOf("src/a.ts", root), {
		relative: "src/a.ts",
		previewable: true,
	});
	assert.equal(previewTargetOf("/etc/passwd", root), null);
});

test("cwd 为符号链接别名：相对与 realpath 绝对都换算成同一 relative", (t) => {
	const root = workspace(t);
	putFile(root, "src/a.ts");
	const alias = join(realpathSync(mkdtempSync(join(tmpdir(), "issue67-alias-"))), "cwd-link");
	symlinkSync(root, alias);
	t.after(() => rmSync(join(alias, ".."), { recursive: true, force: true }));
	assertPreviewable(read("src/a.ts", alias), "src/a.ts", alias);
	// header.cwd 是别名、工具参数是 realpath 绝对：按 realpath containment 判定后换算。
	assertPreviewable(read(join(root, "src/a.ts"), alias), "src/a.ts", alias);
});
