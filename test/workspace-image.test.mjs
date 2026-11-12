// issue #94：只读图片字节端点 GET /m/api/workspace-image。
//
// 安全边界：只允许当前会话 cwd（且属于 workspaceRegistry 登记工作区）内的普通图片；
// realpath + 前缀校验拒绝 .. / symlink / 任意绝对路径；扩展名+magic；字节/像素限制；
// 错误不泄露主机路径；ETag/304；HEAD。

import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply } from "../lib/index.js";

const CONFIG = {
	path: "/m", authToken: "1234567890123456", cookieName: "dsh_mobile_token",
	trustedHosts: [], sessionTtlMs: 60_000, rechargeUrl: "https://example.test/top-up",
	maxConnections: 4, pushUrls: [], pushCooldownMs: 1, doneGraceMs: 1,
	pushContent: "minimal", rateLimit: {}, lanBridge: { enabled: false, port: 3080, host: "127.0.0.1" },
	approvalMode: "mobile",
};

// 1x1 PNG（带合法 CRC），用于真实解码前嗅探/尺寸路径。
const PNG_1X1 = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAF9Z2ZkAAAAASUVORK5CYII=",
	"base64",
);
const JPEG_HEAD = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00]);

class FakeResponse extends EventEmitter {
	constructor() { super(); this.headersSent = false; this.chunks = []; }
	writeHead(statusCode, headers = {}) { this.statusCode = statusCode; this.headers = headers; this.headersSent = true; }
	write(chunk) { this.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk))); return true; }
	end(chunk = "") { if (chunk !== "") this.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk))); this.emit("finish"); }
	destroy() { this.destroyed = true; this.emit("close"); }
}
class FakeRequest extends EventEmitter {
	constructor(url, method = "GET", headers = {}) {
		super(); this.url = url; this.method = method;
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken, ...headers };
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

function harness({ cwd, registered = true } = {}) {
	const routes = [];
	const session = { id: "s1", header: { cwd } };
	const services = new Map([
		["sessions", { get: (id) => id === "s1" ? session : undefined }],
		["workspaceRegistry", { list: () => registered ? [{ path: cwd }] : [] }],
	]);
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43140, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
		get(name) { return services.get(name); },
		provide(name, value) { services.set(name, value); },
		on() { return () => {}; },
		effect(cb) { const d = cb?.(); return typeof d === "function" ? d : () => {}; },
		inject() {},
	};
	const dispose = apply(ctx, CONFIG);
	return {
		route: routes.find((r) => r.path === "/m/api").handler,
		clean() { dispose?.(); },
	};
}

async function request(route, query, { method = "GET", headers = {} } = {}) {
	const req = new FakeRequest(`/m/api/workspace-image?${query}`, method, headers);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	let json = null;
	try { json = JSON.parse(Buffer.concat(res.chunks).toString("utf8")); } catch {}
	return { status: res.statusCode, headers: res.headers ?? {}, bytes: Buffer.concat(res.chunks), json };
}

function workspace() {
	const root = mkdtempSync(join(tmpdir(), "workspace-image-"));
	const cwd = join(root, "project");
	mkdirSync(cwd, { recursive: true });
	writeFileSync(join(cwd, "pic.png"), PNG_1X1);
	writeFileSync(join(cwd, "photo.jpg"), Buffer.concat([JPEG_HEAD, Buffer.alloc(64)]));
	writeFileSync(join(cwd, "fake.png"), Buffer.from("not an image"));
	writeFileSync(join(cwd, "note.txt"), "hello");
	writeFileSync(join(root, "outside.png"), PNG_1X1);
	return { root, cwd };
}

test("GET /workspace-image：合法 PNG（相对/绝对）→ 200 + 类型/缓存/ETag；HEAD/304", async () => {
	const { root, cwd } = workspace();
	const h = harness({ cwd });
	try {
		const rel = await request(h.route, `sessionId=s1&path=${encodeURIComponent("pic.png")}`);
		assert.equal(rel.status, 200);
		assert.equal(rel.headers["content-type"], "image/png");
		assert.equal(rel.headers["cache-control"], "private, max-age=86400");
		assert.ok(rel.headers.etag);
		assert.equal(rel.headers["x-content-type-options"], "nosniff");
		assert.deepEqual(rel.bytes, PNG_1X1);

		const absolute = await request(h.route, `sessionId=s1&path=${encodeURIComponent(join(cwd, "pic.png"))}`);
		assert.equal(absolute.status, 200);

		const head = await request(h.route, `sessionId=s1&path=${encodeURIComponent("pic.png")}`, { method: "HEAD" });
		assert.equal(head.status, 200);
		assert.equal(head.bytes.length, 0);
		assert.equal(head.headers["content-length"], String(PNG_1X1.length));

		const cached = await request(h.route, `sessionId=s1&path=${encodeURIComponent("pic.png")}`, { headers: { "if-none-match": rel.headers.etag } });
		assert.equal(cached.status, 304);
		assert.equal(cached.bytes.length, 0);
	} finally { rmSync(root, { recursive: true, force: true }); h.clean(); }
});

test("GET /workspace-image：目录逃逸 / 绝对路径越界 / symlink 逃逸 → 403", async () => {
	const { root, cwd } = workspace();
	const h = harness({ cwd });
	try {
		for (const path of ["../outside.png", join(root, "outside.png"), "sub/../../outside.png"]) {
			const res = await request(h.route, `sessionId=s1&path=${encodeURIComponent(path)}`);
			assert.equal(res.status, 403, path);
			assert.equal(res.json.error, "path-outside-workspace");
			assert.ok(!JSON.stringify(res.json).includes(root), "错误不得泄露主机路径");
		}
		mkdirSync(join(cwd, "linkdir"), { recursive: true });
		symlinkSync(join(root, "outside.png"), join(cwd, "linkdir", "escape.png"));
		const symlink = await request(h.route, `sessionId=s1&path=${encodeURIComponent("linkdir/escape.png")}`);
		assert.equal(symlink.status, 403);
	} finally { rmSync(root, { recursive: true, force: true }); h.clean(); }
});

test("GET /workspace-image：非图片/扩展名与 magic 不符 → 415；缺文件/会话 → 4xx", async () => {
	const { root, cwd } = workspace();
	const h = harness({ cwd });
	try {
		const txt = await request(h.route, `sessionId=s1&path=${encodeURIComponent("note.txt")}`);
		assert.equal(txt.status, 415);
		const fake = await request(h.route, `sessionId=s1&path=${encodeURIComponent("fake.png")}`);
		assert.equal(fake.status, 415);
		const missing = await request(h.route, `sessionId=s1&path=${encodeURIComponent("none.png")}`);
		assert.equal(missing.status, 404);
		const noSession = await request(h.route, `sessionId=nope&path=${encodeURIComponent("pic.png")}`);
		assert.equal(noSession.status, 404);
		const noPath = await request(h.route, "sessionId=s1");
		assert.equal(noPath.status, 400);
		const post = await request(h.route, `sessionId=s1&path=${encodeURIComponent("pic.png")}`, { method: "POST" });
		assert.equal(post.status, 405);
	} finally { rmSync(root, { recursive: true, force: true }); h.clean(); }
});

test("GET /workspace-image：字节/像素/工作区授权限制", async () => {
	const { root, cwd } = workspace();
	const h = harness({ cwd });
	try {
		// 字节超限：PNG 头 + 8MB 零，stat 阶段即 413。
		const oversized = Buffer.concat([PNG_1X1, Buffer.alloc(8 * 1024 * 1024)]);
		writeFileSync(join(cwd, "big.png"), oversized);
		const big = await request(h.route, `sessionId=s1&path=${encodeURIComponent("big.png")}`);
		assert.equal(big.status, 413);
		assert.equal(big.json.error, "image-too-large");

		// 像素超限：PNG IHDR 宽 9000 > 8192。
		const huge = Buffer.from(PNG_1X1);
		huge.writeUInt32BE(9000, 16);
		writeFileSync(join(cwd, "huge.png"), huge);
		const pix = await request(h.route, `sessionId=s1&path=${encodeURIComponent("huge.png")}`);
		assert.equal(pix.status, 413);

		// cwd 未登记为工作区 → 403。
		const denied = harness({ cwd, registered: false });
		try {
			const res = await request(denied.route, `sessionId=s1&path=${encodeURIComponent("pic.png")}`);
			assert.equal(res.status, 403);
			assert.equal(res.json.error, "workspace-not-authorized");
		} finally { denied.clean(); }
	} finally { rmSync(root, { recursive: true, force: true }); h.clean(); }
});
