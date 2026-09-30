/**
 * 目录列举与文件下载通道的 HTTP 契约测试（issue #15 的落地 seam）。
 *
 * 这两条路由此前没有任何 HTTP 级覆盖，却将成为「会话文件浏览」的底座，
 * 因此在这里固定它们的可观察行为：成功形状、隐藏点开头条目、错误码，
 * 以及文件下载的响应头与字节。
 *
 * 测试通过插件真实的 `apply(ctx, CONFIG)` 取得 `/m/api` 处理器，用假 req/res
 * 直接驱动，无需起真实服务器（与 interaction-settlement.test.mjs 同一 seam）。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
};

class FakeResponse extends EventEmitter {
	constructor() {
		super();
		this.headersSent = false;
		this.statusCode = 0;
		this.headers = {};
		this.chunks = [];
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
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken };
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

function createHarness() {
	const routes = [];
	const provided = new Map();
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
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
		clean() { dispose?.(); },
	};
}

async function call(route, { url, method = "GET" } = {}) {
	const req = new FakeRequest(url, method);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	const text = Buffer.concat(res.chunks).toString("utf8");
	let body;
	try { body = JSON.parse(text); } catch { body = text; }
	return { status: res.statusCode, headers: res.headers, body, raw: Buffer.concat(res.chunks) };
}

/** 造一个临时工作区目录，返回其绝对路径。 */
function makeWorkspace() {
	const root = mkdtempSync(join(tmpdir(), "wb-http-"));
	mkdirSync(join(root, "src"));
	writeFileSync(join(root, "README.md"), "hello 世界\n");
	writeFileSync(join(root, ".hidden-file"), "secret\n");
	writeFileSync(join(root, "data.bin"), Buffer.from([0, 1, 2, 3]));
	return root;
}

test("directories：列出目录与文件，隐藏点开头条目", async () => {
	const { route, clean } = createHarness();
	try {
		const root = makeWorkspace();
		const res = await call(route, { url: `/m/api/directories?path=${encodeURIComponent(root)}` });
		assert.equal(res.status, 200);
		assert.equal(res.body.ok, true);
		assert.deepEqual(res.body.dirs, ["src"]);
		const files = res.body.files;
		assert.ok(files.includes("README.md"), "普通文件应出现");
		assert.ok(!files.includes(".hidden-file"), "点开头文件必须被隐藏（.git/ 同此规则）");
		// 现状：`sep` 只在根视图（空 path）返回，非根视图没有该字段。
		// App 侧因此必须能在缺少 sep 时自行兜底（见 session_files_controller.dart），
		// 这里把该事实固定下来，免得将来有人以为子目录响应一定带 sep。
		assert.equal(res.body.sep, undefined, "非根视图不返回 sep");
	} finally {
		clean();
	}
});

test("directories：空 path 返回根视图", async () => {
	const { route, clean } = createHarness();
	try {
		const res = await call(route, { url: "/m/api/directories?path=" });
		assert.equal(res.status, 200);
		assert.equal(res.body.path, "");
		assert.ok(Array.isArray(res.body.dirs));
		assert.ok(res.body.dirs.length >= 1);
		assert.equal(res.body.sep, "/", "根视图才带 sep（App 据此拼子目录，Linux 下为 /）");
	} finally {
		clean();
	}
});

test("directories：路径不存在时返回 directory-unreadable", async () => {
	const { route, clean } = createHarness();
	try {
		const res = await call(route, { url: "/m/api/directories?path=/definitely/not/here-xyz" });
		assert.equal(res.status, 400);
		assert.equal(res.body.error, "directory-unreadable");
		// 错误体是 { error, detail }，没有 ok:false；且 detail 里的主机路径已脱敏。
		assert.equal(res.body.ok, undefined, "错误体不含 ok 字段");
		assert.ok(!JSON.stringify(res.body).includes("/definitely/not/here-xyz"), "主机路径必须脱敏");
	} finally {
		clean();
	}
});

test("directories：路径是文件而非目录时同样报错而不是崩", async () => {
	const { route, clean } = createHarness();
	try {
		const root = makeWorkspace();
		const res = await call(route, { url: `/m/api/directories?path=${encodeURIComponent(join(root, "README.md"))}` });
		assert.equal(res.status, 400);
		assert.equal(res.body.error, "directory-unreadable");
	} finally {
		clean();
	}
});

test("files：下载返回文件字节与下载响应头", async () => {
	const { route, clean } = createHarness();
	try {
		const root = makeWorkspace();
		const res = await call(route, { url: `/m/api/files?path=${encodeURIComponent(join(root, "README.md"))}` });
		assert.equal(res.status, 200);
		assert.equal(res.raw.toString("utf8"), "hello 世界\n");
		assert.match(String(res.headers["content-disposition"]), /attachment/);
		assert.equal(res.headers["cache-control"], "no-store");
	} finally {
		clean();
	}
});

test("files：二进制文件按字节返回，不被改写", async () => {
	const { route, clean } = createHarness();
	try {
		const root = makeWorkspace();
		const res = await call(route, { url: `/m/api/files?path=${encodeURIComponent(join(root, "data.bin"))}` });
		assert.equal(res.status, 200);
		assert.deepEqual([...res.raw], [0, 1, 2, 3]);
	} finally {
		clean();
	}
});

test("files：缺 path 返回 bad-request；路径不存在返回 file-not-found", async () => {
	const { route, clean } = createHarness();
	try {
		const missing = await call(route, { url: "/m/api/files?path=" });
		assert.equal(missing.status, 400);
		assert.equal(missing.body.error, "bad-request");

		const notFound = await call(route, { url: "/m/api/files?path=/definitely/not/here-xyz.txt" });
		assert.equal(notFound.status, 404);
		assert.equal(notFound.body.error, "file-not-found");
	} finally {
		clean();
	}
});

test("files：路径指向目录时返回 not-a-file", async () => {
	const { route, clean } = createHarness();
	try {
		const root = makeWorkspace();
		const res = await call(route, { url: `/m/api/files?path=${encodeURIComponent(root)}` });
		assert.equal(res.status, 400);
		assert.equal(res.body.error, "not-a-file");
	} finally {
		clean();
	}
});

test("files：错误响应不回显主机路径（脱敏）", async () => {
	const { route, clean } = createHarness();
	try {
		const root = makeWorkspace();
		const res = await call(route, { url: `/m/api/files?path=${encodeURIComponent(join(root, "nope.txt"))}` });
		assert.equal(res.status, 404);
		const text = JSON.stringify(res.body);
		assert.ok(!text.includes(root), `错误信息不得含主机路径：${text}`);
	} finally {
		clean();
	}
});

/**
 * 记录当前信任模型：文件下载不做工作区包含校验，符号链接可指向工作区外。
 * 这不是"期望的安全行为"，而是把现状固定下来，避免将来收紧时无人察觉，
 * 也避免有人误以为这里已有保护（见 #16；docs/04-security.md 已按现状修正）。
 */
test("files：当前不校验工作区包含（符号链接可越界，记录现状）", async () => {
	const { route, clean } = createHarness();
	try {
		const outside = mkdtempSync(join(tmpdir(), "wb-outside-"));
		writeFileSync(join(outside, "secret.txt"), "outside\n");
		const root = makeWorkspace();
		symlinkSync(join(outside, "secret.txt"), join(root, "link.txt"));

		const res = await call(route, { url: `/m/api/files?path=${encodeURIComponent(join(root, "link.txt"))}` });
		assert.equal(res.status, 200, "现状：符号链接会被跟随");
		assert.equal(res.raw.toString("utf8"), "outside\n");
	} finally {
		clean();
	}
});
