import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { Writable } from "node:stream";
import { test } from "node:test";
import { once } from "node:events";
import { join } from "node:path";

const TOKEN = "0123456789abcdef0123456789abcdef";
const COOKIE_NAME = "dsh_mobile_token";
const APK_BYTES = Buffer.from("test apk bytes\n");
let apply;
let testHome;

class MockResponse extends Writable {
	constructor() {
		super();
		this.statusCode = 200;
		this.headers = {};
		this.headersSent = false;
		this.chunks = [];
	}

	writeHead(status, headers = {}) {
		this.statusCode = status;
		this.headers = Object.fromEntries(Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]));
		this.headersSent = true;
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

function config(updateDir, { lanBridge = { enabled: false, host: "127.0.0.1", port: 3080 } } = {}) {
	return {
		path: "/m",
		authToken: TOKEN,
		cookieName: COOKIE_NAME,
		trustedHosts: [],
		sessionTtlMs: 60_000,
		rechargeUrl: "",
		updateDir,
		maxConnections: 16,
		pushUrls: [],
		pushCooldownMs: 60_000,
		doneGraceMs: 1_000,
		pushContent: "minimal",
		rateLimit: { maxFailures: 10, windowMs: 60_000, blockMs: 60_000 },
		lanBridge,
	};
}

function createContext({ upstreamPort = 3080 } = {}) {
	const routes = [];
	let effectCleanup;
	const ctx = {
		webServer: {
			host: "127.0.0.1",
			port: upstreamPort,
			register(route) {
				routes.push(route);
				return () => {};
			},
		},
		logger: { warn() {}, info() {} },
		provide() {},
		get(name) {
			if (name === "jobs") {
				return {
					list() { return []; },
					onJobsChanged() { return () => {}; },
					onJobDone() { return () => {}; },
				};
			}
			if (name === "agents") return { list() { return []; }, roots() { return []; }, get() {} };
			if (name === "sessions") return { list() { return []; }, get() {} };
			return undefined;
		},
		on() { return () => {}; },
		// Deliberately expose no apiProxy, sessionController, or typertGateway.
		inject() {},
		effect(fn) {
			effectCleanup = fn();
			return effectCleanup;
		},
	};
	return {
		ctx,
		routes,
		dispose() {
			effectCleanup?.();
		},
	};
}

function apiRouteOf(routes) {
	return routes.find((route) => route.kind === "prefix" && route.path === "/m/api");
}

function request(route, {
	url,
	method = "GET",
	host = "127.0.0.1:3080",
	remoteAddress = "127.0.0.1",
	headers = {},
} = {}) {
	const req = {
		method,
		url,
		headers: { host, ...headers },
		socket: { remoteAddress },
		on() { return this; },
	};
	const res = new MockResponse();
	const finished = once(res, "finish");
	route.handler(req, res);
	return finished.then(() => ({
		status: res.statusCode,
		headers: res.headers,
		body: res.body(),
		json: () => JSON.parse(res.body().toString("utf8")),
	}));
}

async function fixture({ manifest = {}, manifestText, apkBytes = APK_BYTES } = {}) {
	const dir = await mkdtemp(join(tmpdir(), "dsh-mobile-update-"));
	const apkPath = join(dir, "mobile.apk");
	await writeFile(apkPath, apkBytes);
	const manifestBody = manifestText ?? JSON.stringify({
		version: "3.1.1+1",
		apk: "mobile.apk",
		sha256: createHash("sha256").update(apkBytes).digest("hex"),
		size: apkBytes.length,
		notes: "contract fixture",
		...manifest,
	});
	await writeFile(join(dir, "manifest.json"), manifestBody);
	return dir;
}

async function withHarness(updateDir, callback, options = {}) {
	const harness = createContext(options);
	apply(harness.ctx, config(updateDir, options));
	try {
		return await callback({ ...harness, api: apiRouteOf(harness.routes) });
	} finally {
		harness.dispose();
	}
}

async function listen(server, ...args) {
	server.listen(...args);
	await once(server, "listening");
	return server.address().port;
}

async function close(server) {
	if (!server.listening) return;
	server.close();
	await once(server, "close");
}

async function fetchRetry(url, init) {
	let lastError;
	for (let attempt = 0; attempt < 50; attempt++) {
		try {
			return await fetch(url, init);
		} catch (error) {
			lastError = error;
			await new Promise((resolve) => setTimeout(resolve, 10));
		}
	}
	throw lastError;
}

// Keep the process-local persistence files isolated from a developer's profile.
test.before(async () => {
	testHome = await mkdtemp(join(tmpdir(), "dsh-mobile-update-home-"));
	process.env.HOME = testHome;
	({ apply } = await import("../lib/index.js"));
});

test.after(async () => {
	await rm(testHome, { recursive: true, force: true });
});

test("update routes keep their HTTP contract without RC1 remote services", async () => {
	const updateDir = await fixture();
	try {
		await withHarness(updateDir, async ({ routes, api }) => {
			assert.ok(api, "the RC1 WebServer prefix route must be registered");
			assert.deepEqual(routes.map(({ kind, path }) => ({ kind, path })), [
				{ kind: "prefix", path: "/m/api" },
				{ kind: "exact", path: "/m/qr.png" },
			]);

			const noToken = await request(api, { url: "/m/api/update/manifest" });
			assert.equal(noToken.status, 401);
			assert.equal(noToken.json().error, "auth-required");

			const wrongToken = await request(api, {
				url: "/m/api/update/manifest",
				headers: { "x-mobile-token": "wrong-token" },
			});
			assert.equal(wrongToken.status, 401);
			assert.equal(wrongToken.json().error, "auth-required");

			const badHost = await request(api, {
				url: "/m/api/update/manifest",
				headers: { "x-mobile-token": TOKEN },
				host: "evil.example:3080",
				remoteAddress: "192.0.2.10",
			});
			assert.equal(badHost.status, 403);
			assert.equal(badHost.json().error, "host-not-allowed");

			const manifest = await request(api, {
				url: "/m/api/update/manifest",
				headers: { cookie: `${COOKIE_NAME}=${TOKEN}` },
			});
			assert.equal(manifest.status, 200);
			assert.equal(manifest.json().manifest.version, "3.1.1+1");
			assert.equal(manifest.json().manifest.apk, "mobile.apk");

			const apk = await request(api, {
				url: "/m/api/update/apk",
				headers: { "x-mobile-token": TOKEN },
			});
			assert.equal(apk.status, 200);
			assert.equal(apk.headers["content-type"], "application/vnd.android.package-archive");
			assert.equal(Number(apk.headers["content-length"]), APK_BYTES.length);
			assert.deepEqual(apk.body, APK_BYTES);
		});
	} finally {
		await rm(updateDir, { recursive: true, force: true });
	}

	const missingConfig = await withHarness("", async ({ api }) => request(api, {
		url: "/m/api/update/manifest",
		headers: { "x-mobile-token": TOKEN },
	}));
	assert.equal(missingConfig.status, 503);
	assert.equal(missingConfig.json().error, "update-not-configured");

	const invalidDir = await fixture({ manifestText: "not json" });
	try {
		const invalid = await withHarness(invalidDir, async ({ api }) => request(api, {
			url: "/m/api/update/manifest",
			headers: { "x-mobile-token": TOKEN },
		}));
		assert.equal(invalid.status, 404);
		assert.equal(invalid.json().error, "update-manifest-invalid");
	} finally {
		await rm(invalidDir, { recursive: true, force: true });
	}

	const missingApkDir = await fixture({ manifest: { apk: "missing.apk" } });
	try {
		const missingApk = await withHarness(missingApkDir, async ({ api }) => request(api, {
			url: "/m/api/update/manifest",
			headers: { "x-mobile-token": TOKEN },
		}));
		assert.equal(missingApk.status, 404);
		assert.equal(missingApk.json().error, "update-apk-missing");
	} finally {
		await rm(missingApkDir, { recursive: true, force: true });
	}

	const traversalDir = await fixture({ manifest: { apk: "../outside.apk" } });
	try {
		const traversal = await withHarness(traversalDir, async ({ api }) => request(api, {
			url: "/m/api/update/manifest",
			headers: { "x-mobile-token": TOKEN },
		}));
		assert.equal(traversal.status, 404);
		assert.equal(traversal.json().error, "update-apk-missing");
	} finally {
		await rm(traversalDir, { recursive: true, force: true });
	}

	const mismatchDir = await fixture({ manifest: { sha256: "0".repeat(64) } });
	try {
		const mismatch = await withHarness(mismatchDir, async ({ api }) => request(api, {
			url: "/m/api/update/apk",
			headers: { "x-mobile-token": TOKEN },
		}));
		assert.equal(mismatch.status, 500);
		assert.equal(mismatch.json().error, "update-apk-checksum-mismatch");
	} finally {
		await rm(mismatchDir, { recursive: true, force: true });
	}
});

test("LAN bridge forwards update API and excludes internal and QR routes", async () => {
	const upstreamRequests = [];
	const upstream = createServer((req, res) => {
		upstreamRequests.push({ url: req.url, host: req.headers.host });
		res.writeHead(200, { "content-type": "text/plain", "content-length": "2" });
		res.end("ok");
	});
	const upstreamPort = await listen(upstream, 0, "127.0.0.1");
	const bridgeProbe = createServer();
	const bridgePort = await listen(bridgeProbe, 0, "127.0.0.1");
	await close(bridgeProbe);

	try {
		await withHarness("", async ({ ctx }) => {
			const manifest = await fetchRetry(`http://127.0.0.1:${bridgePort}/m/api/update/manifest`, {
				headers: { "x-mobile-token": TOKEN },
			});
			assert.equal(manifest.status, 200);
			assert.equal(await manifest.text(), "ok");
			assert.deepEqual(upstreamRequests[0], {
				url: "/m/api/update/manifest",
				host: `127.0.0.1:${upstreamPort}`,
			});

			const internalApi = await fetch(`http://127.0.0.1:${bridgePort}/api`, {
				headers: { "x-mobile-token": TOKEN },
			});
			assert.equal(internalApi.status, 404);
			const qrConfig = await fetch(`http://127.0.0.1:${bridgePort}/m/api/qr-config`, {
				headers: { "x-mobile-token": TOKEN },
			});
			assert.equal(qrConfig.status, 404);
			assert.equal(upstreamRequests.length, 1, "blocked bridge paths must not reach the WebServer");
			assert.equal(ctx.webServer.port, upstreamPort);
		}, { upstreamPort, lanBridge: { enabled: true, host: "127.0.0.1", port: bridgePort } });
	} finally {
		await close(upstream);
	}
});
