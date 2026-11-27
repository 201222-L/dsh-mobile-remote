// issue #131：SSE 配额满时不再直接 503——先驱逐「最旧且超过安全年龄」的陈旧连接。
//
// 真机症状：一台手机 `mobileOnline = 16 / 16`，之后所有 `/m/api/events` 503，
// 只能重启宿主恢复。App 侧（9670849）已修连接泄漏；本测试锁宿主侧兜底语义：
// 1) 名额未满：连接正常，诊断能区分活跃/陈旧；
// 2) 满额且都在安全年龄内：不踢活跃连接，503 带可归因指标；
// 3) 满额且存在超过安全年龄的连接：驱逐最旧一条后接受新连接，不扩大 maxConnections；
// 4) 被驱逐的客户端按既有重连逻辑重新连回来（用同一路由再连接模拟），连接数不被放大。
import test, { mock } from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { Writable } from "node:stream";
import { apply } from "../lib/index.js";

const AUTH_TOKEN = "fixture-sse-token-123456";

class MockResponse extends Writable {
	constructor() {
		super();
		this.statusCode = 200;
		this.headers = {};
		this.chunks = [];
		this.destroyedByTest = false;
	}

	writeHead(status, headers = {}) {
		this.statusCode = status;
		this.headers = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), v]));
		return this;
	}

	_write(chunk, encoding, callback) {
		this.chunks.push(Buffer.isBuffer(chunk) ? Buffer.from(chunk) : Buffer.from(chunk, encoding));
		callback();
	}

	body() {
		return Buffer.concat(this.chunks);
	}
}

function config(over = {}) {
	return {
		path: "/m",
		authToken: AUTH_TOKEN,
		cookieName: "dsh_mobile_token",
		trustedHosts: [],
		sessionTtlMs: 60_000,
		rechargeUrl: "",
		updateDir: "",
		// 本测试只关心 SSE 配额，不应产生任何出网行为。
		pluginUpdateManifest: "off",
		maxConnections: 3,
		pushUrls: [],
		pushCooldownMs: 60_000,
		doneGraceMs: 1_000,
		pushContent: "minimal",
		rateLimit: { maxFailures: 10, windowMs: 60_000, blockMs: 60_000 },
		lanBridge: { enabled: false, host: "127.0.0.1", port: 3080 },
		...over,
	};
}

function createContext() {
	const routes = [];
	const logs = [];
	let effectCleanup;
	const ctx = {
		webServer: {
			host: "127.0.0.1",
			port: 3080,
			register(route) {
				routes.push(route);
				return () => {};
			},
		},
		logger: {
			warn: (m) => logs.push({ level: "warn", message: String(m) }),
			info: (m) => logs.push({ level: "info", message: String(m) }),
		},
		provide() {},
		get(name) {
			if (name === "agents") return { list: () => [], roots: () => [], get: () => undefined };
			if (name === "sessions") return { list: () => [], get: () => undefined };
			return undefined;
		},
		on() {
			return () => {};
		},
		inject() {},
		effect(fn) {
			effectCleanup = fn();
			return effectCleanup;
		},
	};
	return {
		ctx,
		routes,
		logs,
		dispose() {
			effectCleanup?.();
		},
	};
}

function apiRouteOf(routes) {
	return routes.find((route) => route.kind === "prefix" && route.path === "/m/api");
}

function fakeReq(url) {
	return {
		method: "GET",
		url,
		headers: { host: "127.0.0.1:3080", "x-mobile-token": AUTH_TOKEN },
		socket: { remoteAddress: "127.0.0.1" },
		on() {
			return this;
		},
	};
}

/** 打开一条 SSE 连接（不等待结束：正常连接会保持打开）。 */
function openSse(route) {
	const res = new MockResponse();
	route.handler(fakeReq("/m/api/events"), res);
	return res;
}

/** 普通 JSON 请求：等待响应结束。 */
async function request(route, url) {
	const res = new MockResponse();
	route.handler(fakeReq(url), res);
	if (!res.writableFinished) await once(res, "finish");
	const text = res.body().toString("utf8");
	return { status: res.statusCode, headers: res.headers, body: JSON.parse(text) };
}

function makeHarness(over = {}) {
	const harness = createContext();
	const dispose = apply(harness.ctx, config(over));
	const route = apiRouteOf(harness.routes);
	return {
		route,
		logs: harness.logs,
		clean() {
			dispose?.();
			harness.dispose();
		},
	};
}

test("issue #131：名额未满时连接正常，诊断可区分活跃与陈旧", async (t) => {
	const h = makeHarness({ maxConnections: 3, sseEvictMinAgeMs: 60_000 });
	t.after(() => h.clean());

	const first = openSse(h.route);
	const second = openSse(h.route);
	assert.equal(first.statusCode, 200);
	assert.equal(second.statusCode, 200);
	assert.equal(first.writableEnded, false, "SSE 连接应保持打开");

	const diag = await request(h.route, "/m/api/diagnostics");
	assert.equal(diag.status, 200);
	const summary = diag.body.checks.sseConnections;
	assert.equal(typeof summary, "string");
	assert.match(summary, /^2 \/ 3 · 最旧 /, "诊断应报出连接数 / 上限与最旧连接年龄");
	assert.match(summary, /满龄候选 0/, "满龄候选只表示年龄门槛，不等于陈旧数");
	assert.match(summary, /stalled 0/);
	assert.match(summary, /安全年龄 1m0s/);
	assert.match(summary, /累计驱逐 0/);
	assert.match(summary, /累计拒绝 0/);

	// runtime.metrics 增量（issue #131）：mobileOnline 语义保持不变，新增年龄/空闲/计数。
	const metrics = diag.body.runtime.metrics;
	assert.equal(metrics.mobileOnline, 2);
	assert.equal(metrics.mobileEvicted, 0);
	assert.equal(metrics.mobileRejected, 0);
	assert.equal(metrics.mobileStalled, 0);
	assert.ok(metrics.mobileOldestAgeMs >= 0 && metrics.mobileOldestAgeMs < 60_000);
	assert.ok(metrics.mobileOldestIdleMs >= 0);
});

test("issue #131：满额且无陈旧连接 → 503，不踢活跃连接，附带归因指标", async (t) => {
	const h = makeHarness({ maxConnections: 2, sseEvictMinAgeMs: 60_000 });
	t.after(() => h.clean());

	const first = openSse(h.route);
	const second = openSse(h.route);
	assert.equal(first.statusCode, 200);
	assert.equal(second.statusCode, 200);

	const rejected = openSse(h.route);
	assert.equal(rejected.statusCode, 503);
	assert.equal(rejected.headers["retry-after"], "5", "503 应提示客户端退避");
	const body = JSON.parse(rejected.body().toString("utf8"));
	assert.equal(body.error, "too-many-connections");
	assert.equal(body.mobileOnline, 2);
	assert.equal(body.maxConnections, 2, "不得为了接纳连接而放大配额");
	assert.equal(body.evictMinAgeMs, 60_000);
	assert.ok(body.oldestAgeMs >= 0 && body.oldestAgeMs < 60_000, "最旧连接仍在安全年龄内");
	assert.equal(first.destroyed, false, "安全年龄内的活跃连接不能因满额被踢");
	assert.equal(second.destroyed, false);
	assert.ok(
		h.logs.some((entry) => entry.level === "warn" && entry.message.includes("SSE reject") && entry.message.includes("reason=no-eligible")),
		"503 必须留可归因日志（30s 汇总）",
	);

	const diag = await request(h.route, "/m/api/diagnostics");
	assert.equal(diag.body.runtime.metrics.mobileOnline, 2);
	assert.equal(diag.body.runtime.metrics.mobileRejected, 1);
	assert.equal(diag.body.runtime.metrics.mobileEvicted, 0);
});

test("issue #131：满额且有超过安全年龄的连接 → 驱逐最旧后接受新连接", async (t) => {
	mock.timers.enable({ apis: ["Date"] });
	t.after(() => mock.timers.reset());
	const h = makeHarness({ maxConnections: 2, sseEvictMinAgeMs: 60_000 });
	t.after(() => h.clean());

	const oldest = openSse(h.route);
	const newer = openSse(h.route);
	assert.equal(oldest.statusCode, 200);
	assert.equal(newer.statusCode, 200);

	// 超过安全年龄（60s）后，新连接应驱逐最旧的 rather than 永久 503。
	mock.timers.tick(61_000);
	const replacement = openSse(h.route);
	assert.equal(replacement.statusCode, 200, "存在陈旧连接时必须恢复连接能力");
	assert.equal(oldest.destroyed, true, "被驱逐的应是最旧连接");
	assert.equal(newer.destroyed, false, "较新的连接不应被驱逐");

	const diag = await request(h.route, "/m/api/diagnostics");
	assert.match(diag.body.checks.sseConnections, /^2 \/ 2 · 最旧 /);
	assert.match(diag.body.checks.sseConnections, /满龄候选 1/, "剩下一台达到年龄门槛的连接");
	assert.equal(diag.body.runtime.metrics.mobileOnline, 2, "驱逐 + 新连接后连接数仍为上限，计数不涨不跌");
	assert.equal(diag.body.runtime.metrics.mobileEvicted, 1);
	assert.equal(diag.body.runtime.metrics.mobileRejected, 0);
	assert.ok(diag.body.runtime.metrics.mobileOldestAgeMs >= 60_000);

	assert.ok(
		h.logs.some((entry) => entry.level === "warn" && entry.message.includes("SSE evict") && entry.message.includes("reason=same-client-ip") && entry.message.includes("stalled=")),
		"驱逐日志必须含 id/age/idle/remote/app/reason",
	);
	assert.equal(h.logs.filter((entry) => entry.message.includes("SSE close id=c1")).length, 0, "被驱逐连接只留 evict 日志，不重复 close");

	// 再过 61s：剩余的最旧连接也可被驱逐——反复满额不会永久卡死。
	mock.timers.tick(61_000);
	const secondReplacement = openSse(h.route);
	assert.equal(secondReplacement.statusCode, 200);
	assert.equal(newer.destroyed, true, "第二次驱逐应轮到原先较新的连接");
	assert.equal(replacement.destroyed, false);
});
