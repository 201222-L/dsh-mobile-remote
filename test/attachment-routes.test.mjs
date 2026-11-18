/**
 * issue #78：/m/api/attachment 的 RPC 入参形状回归。
 *
 * 新 DSH `session.attachment` strict schema 要求
 * `{sessionId, attachment:{attachmentId,mediaType,bytes,width,height,name?}}`；
 * 旧实现只传 `{sessionId, attachmentId}`，被网关 400 拒绝，导致 alpha.11 所有图片
 * 加载失败。这里用假 ctx + 假 typertGateway 固定真实 HTTP 形状与入参，并覆盖
 * 完整 ref 解析（live/休眠）、坏字段 404、非法 id 不扫事件、LRU 命中/不污染。
 */
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { apply, attachmentRefFrom, attachmentIdValid, extractAttachmentRef } from "../lib/index.js";

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
	constructor() { super(); this.statusCode = 0; this.headers = {}; this.chunks = []; this.headersSent = false; }
	writeHead(statusCode, headers = {}) { this.statusCode = statusCode; this.headers = headers; this.headersSent = true; }
	write(chunk) { this.chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk))); return true; }
	end(chunk = "") { if (chunk !== "") this.write(chunk); this.emit("finish"); }
	destroy() { this.destroyed = true; this.emit("close"); }
}
class FakeRequest extends EventEmitter {
	constructor(url, method = "GET") {
		super();
		this.url = url; this.method = method;
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken };
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

const USER_ATTACHMENT = {
	attachmentId: "sha256:user-0001",
	mediaType: "image/png",
	bytes: 4,
	width: 10,
	height: 20,
	name: "user-shot.png",
};
const TOOL_ATTACHMENT = {
	attachmentId: "sha256:tool-0002",
	mediaType: "image/jpeg",
	bytes: 5,
	width: 780,
	height: 1688,
	name: "01-standard-running-provisional-tool.png",
};
const INVALID_ATTACHMENT = {
	// bytes/width/height 缺失：旧/坏的 flat 元数据，严格 schema 会 400，必须 fail-closed。
	attachmentId: "sha256:bad-0003",
	mediaType: "image/png",
};

function sessionEvents() {
	return [
		{
			seq: 1,
			type: "user/message",
			data: { message: { role: "user", content: [
				{ type: "text", text: "看图" },
				{ type: "image", attachment: { ...USER_ATTACHMENT } },
			] } },
		},
		{
			seq: 2,
			type: "tool/result",
			data: { message: { role: "tool", content: [
				{ type: "tool-result", content: [{ type: "text", text: "read" }, { type: "image", attachment: { ...TOOL_ATTACHMENT } }] },
			] } },
		},
		{
			seq: 3,
			type: "tool/result",
			// 服务端投影的 images[]（只有元数据，没有 bytes）：不得直接拿去当 ref。
			data: { images: [{ ...INVALID_ATTACHMENT }] },
		},
	];
}

function createHarness({ live = true, events = sessionEvents(), readSession = null } = {}) {
	const routes = [];
	const provided = new Map();
	const calls = [];
	const scans = { count: 0 };
	const session = {
		id: "s1",
		header: { id: "s1", cwd: "/tmp/proj" },
		snapshotEvents() { scans.count += 1; return events; },
	};
	provided.set("sessions", { get: (id) => (live && id === "s1" ? session : undefined), list: () => [session] });
	if (readSession !== null) provided.set("sessionQuery", { readSession: async (id) => (id === "s1" ? readSession : (() => { throw Object.assign(new Error("not found"), { code: "SESSION_QUERY_SESSION_NOT_FOUND" }); })()) });
	const gateway = {
		async invokeRpc(endpoint, payload, signal, peer) {
			void signal; void peer;
			calls.push({ endpoint, payload });
			const request = payload?.args?.request;
			if (!request || typeof request.sessionId !== "string" || !request.attachment || typeof request.attachment.attachmentId !== "string") {
				return { ok: false, error: { code: "gateway/input-invalid", message: 'wire field "request" failed boundary validation' } };
			}
			const ref = request.attachment;
			const bytes = ref.attachmentId === TOOL_ATTACHMENT.attachmentId
				? Buffer.from("tool!").toString("base64")
				: Buffer.from("user").toString("base64");
			return { ok: true, value: { attachment: { ...ref }, data: bytes } };
		},
	};
	provided.set("typertGateway", gateway);
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43210, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn() {}, info() {} },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on() { return () => {}; },
		effect(callback) { const d = callback?.(); return typeof d === "function" ? d : () => {}; },
		inject() {},
		waterfall: async () => "unavailable",
	};
	const dispose = apply(ctx, CONFIG);
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		calls, scans, provided, live, session,
		clean() { dispose?.(); },
	};
}

async function call(route, url) {
	const req = new FakeRequest(url);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	const raw = Buffer.concat(res.chunks);
	let body;
	try { body = JSON.parse(raw.toString("utf8")); } catch { body = raw; }
	return { status: res.statusCode, headers: res.headers, body, raw };
}

const attachmentUrl = (id) => `/m/api/attachment?sessionId=s1&attachmentId=${encodeURIComponent(id)}`;

test("issue #78：用户附图按新 schema 传完整 ref 并返回字节", async () => {
	const h = createHarness();
	try {
		const res = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(res.status, 200);
		assert.equal(res.headers["content-type"], "image/png");
		assert.equal(res.raw.toString("utf8"), "user");
		assert.deepEqual(JSON.parse(res.headers["x-attachment-meta"]), { width: 10, height: 20, bytes: 4, name: "user-shot.png" });
		assert.equal(h.calls.length, 1);
		assert.equal(h.calls[0].endpoint, "session/attachment");
		// 入参必须是新 strict schema：request.sessionId + request.attachment 完整 ref。
		assert.deepEqual(h.calls[0].payload, {
			args: { request: { sessionId: "s1", attachment: { ...USER_ATTACHMENT } } },
		});
	} finally { h.clean(); }
});

test("issue #78：read_image 的嵌套 tool-result 图片也能解析并传递", async () => {
	const h = createHarness();
	try {
		const res = await call(h.route, attachmentUrl(TOOL_ATTACHMENT.attachmentId));
		assert.equal(res.status, 200);
		assert.equal(res.raw.toString("utf8"), "tool!");
		assert.equal(h.calls[0].payload.args.request.attachment.mediaType, "image/jpeg");
		assert.equal(h.calls[0].payload.args.request.attachment.bytes, 5);
		assert.equal(h.calls[0].payload.args.request.attachment.name, "01-standard-running-provisional-tool.png");
	} finally { h.clean(); }
});

test("issue #78：投影元数据缺 bytes/width/height 时 fail-closed 404，不调用网关", async () => {
	const h = createHarness();
	try {
		const res = await call(h.route, attachmentUrl(INVALID_ATTACHMENT.attachmentId));
		assert.equal(res.status, 404);
		assert.equal(res.body.error, "attachment-not-found");
		assert.equal(h.calls.length, 0, "坏 ref 绝不能发给网关");
	} finally { h.clean(); }
});

test("issue #78：未知 id / 非法 id → 404 且不扫事件、不调网关", async () => {
	const h = createHarness();
	try {
		const unknown = await call(h.route, attachmentUrl("sha256:missing"));
		assert.equal(unknown.status, 404);
		assert.equal(h.calls.length, 0);
		const invalid = await call(h.route, attachmentUrl("bad id\u0000"));
		assert.equal(invalid.status, 404);
		assert.equal(h.calls.length, 0);
		assert.equal(h.scans.count, 1, "非法 id 不应触发事件扫描（未知 id 扫一次）");
	} finally { h.clean(); }
});

test("issue #78：LRU 命中不再扫事件；坏 id 不污染缓存", async () => {
	const h = createHarness();
	try {
		const first = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(first.status, 200);
		assert.equal(h.scans.count, 1);
		const second = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(second.status, 200);
		assert.equal(h.scans.count, 1, "第二次应命中缓存，不重复扫会话事件");
		assert.equal(h.calls.length, 2);
		// 坏 id 两次：都 404，不能把 404 写进缓存影响后续合法 id。
		assert.equal((await call(h.route, attachmentUrl(INVALID_ATTACHMENT.attachmentId))).status, 404);
		assert.equal((await call(h.route, attachmentUrl(INVALID_ATTACHMENT.attachmentId))).status, 404);
		const still = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(still.status, 200);
	} finally { h.clean(); }
});

test("issue #78：休眠会话走 sessionQuery.readSession 解析 ref", async () => {
	const h = createHarness({
		live: false,
		readSession: { events: sessionEvents() },
	});
	try {
		const res = await call(h.route, attachmentUrl(TOOL_ATTACHMENT.attachmentId));
		assert.equal(res.status, 200);
		assert.equal(h.calls[0].payload.args.request.attachment.attachmentId, TOOL_ATTACHMENT.attachmentId);
	} finally { h.clean(); }
});

test("issue #78：会话不存在/无事件 → 404，不调用网关", async () => {
	const h = createHarness({ live: false, events: [] });
	try {
		const res = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(res.status, 404);
		assert.equal(res.body.error, "attachment-not-found");
		assert.equal(h.calls.length, 0);
	} finally { h.clean(); }
});

test("issue #78：响应缺 data → 404", async () => {
	const h = createHarness();
	try {
		h.provided.set("typertGateway", {
			async invokeRpc() { return { ok: true, value: { attachment: { ...USER_ATTACHMENT } } }; },
		});
		const res = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(res.status, 404);
	} finally { h.clean(); }
});

test("issue #78：宿主 storage-missing（attachment-invalid）映射为 404", async () => {
	const h = createHarness();
	try {
		h.provided.set("typertGateway", {
			async invokeRpc() {
				const err = new Error("Attachment object is missing.");
				err.status = 400;
				err.code = "session/attachment-invalid";
				throw err;
			},
		});
		const res = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(res.status, 404);
		assert.equal(res.body.error, "attachment-not-found");
	} finally { h.clean(); }
});

test("issue #78：缓存命中后宿主拒绝会清缓存重扫并重试一次", async () => {
	const h = createHarness();
	try {
		// 先预热缓存（events 扫描 1 次）。
		const warm = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(warm.status, 200);
		assert.equal(h.scans.count, 1);
		// 换一个"第一次失败、第二次成功"的网关：模拟缓存 ref 被宿主拒绝（引用已变化）。
		let attempts = 0;
		const payloads = [];
		h.provided.set("typertGateway", {
			async invokeRpc(endpoint, payload) {
				void endpoint;
				attempts += 1;
				payloads.push(payload);
				if (attempts === 1) throw Object.assign(new Error("stale ref"), { status: 400 });
				const ref = payload.args.request.attachment;
				return { ok: true, value: { attachment: { ...ref }, data: Buffer.from("user").toString("base64") } };
			},
		});
		const res = await call(h.route, attachmentUrl(USER_ATTACHMENT.attachmentId));
		assert.equal(res.status, 200);
		assert.equal(attempts, 2, "缓存 ref 失败 → 应清缓存重扫后重试一次");
		assert.equal(h.scans.count, 2, "重试前应重新扫一次会话事件");
		assert.equal(payloads[1].args.request.attachment.attachmentId, USER_ATTACHMENT.attachmentId);
	} finally { h.clean(); }
});

test("issue #78：纯函数 ref 提取只接受严格完整字段", () => {
	assert.equal(attachmentIdValid("sha256:abc"), true);
	assert.equal(attachmentIdValid(""), false);
	assert.equal(attachmentIdValid("bad id"), false);
	assert.deepEqual(attachmentRefFrom(USER_ATTACHMENT), { ...USER_ATTACHMENT });
	// mediaType 枚举外、bytes/宽高非正数、非对象 → null（不猜、不把半截 ref 发给网关）。
	assert.equal(attachmentRefFrom({ ...USER_ATTACHMENT, mediaType: "image/svg+xml" }), null);
	assert.equal(attachmentRefFrom({ ...USER_ATTACHMENT, bytes: 0 }), null);
	assert.equal(attachmentRefFrom({ ...USER_ATTACHMENT, width: -1 }), null);
	assert.equal(attachmentRefFrom({ ...USER_ATTACHMENT, height: Number.NaN }), null);
	assert.equal(attachmentRefFrom(null), null);
	const extracted = extractAttachmentRef(sessionEvents(), USER_ATTACHMENT.attachmentId);
	assert.deepEqual(extracted, { ...USER_ATTACHMENT });
	assert.equal(extractAttachmentRef(sessionEvents(), "sha256:none"), null);
});
