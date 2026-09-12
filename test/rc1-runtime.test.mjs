import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";
import { mkdtemp, open, readFile, rm, symlink, writeFile } from "node:fs/promises";
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
	lanBridge: { enabled: false },
	approvalMode: "mobile",
};

class FakeResponse extends EventEmitter {
	constructor() {
		super();
		this.headersSent = false;
		this.destroyed = false;
		this.writableLength = 0;
		this.chunks = [];
	}
	writeHead(statusCode, headers) {
		this.statusCode = statusCode;
		this.headers = headers;
		this.headersSent = true;
	}
	write(chunk) {
		this.chunks.push(Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk));
		return true;
	}
	end(chunk = "") {
		if (chunk !== "") this.write(chunk);
		this.emit("finish");
	}
	destroy() {
		if (this.destroyed) return;
		this.destroyed = true;
		this.emit("close");
	}
}

class FakeRequest extends EventEmitter {
	constructor(url, method = "GET") {
		super();
		this.url = url;
		this.method = method;
		this.headers = {
			host: "127.0.0.1",
			"x-mobile-token": CONFIG.authToken,
			"content-type": "application/json",
		};
		this.socket = { remoteAddress: "127.0.0.1" };
	}
}

function createHarness(config = CONFIG, overrides = {}) {
	const routes = [];
	const listeners = [];
	const cleanups = [];
	const ctx = {
		webServer: {
			host: "127.0.0.1",
			port: 43120,
			register(spec) {
				routes.push(spec);
				return () => {};
			},
		},
		logger: { warn() {}, info() {} },
		get(name) {
			const override = overrides.get?.(name);
			if (override !== undefined) return override;
			if (name === "sessions") return { get: () => ({ events: [{ type: "session/title", data: { title: "Test session" } }] }) };
			return undefined;
		},
		provide() {},
		effect(fn) {
			const cleanup = fn?.();
			cleanups.push(cleanup);
			return cleanup;
		},
		inject() {},
		on(event, fn, options) {
			const entry = { event, fn, options };
			listeners.push(entry);
			return () => {
				const index = listeners.indexOf(entry);
				if (index >= 0) listeners.splice(index, 1);
			};
		},
	};
	apply(ctx, config);
	return {
		route: routes.find((route) => route.path === `${config.path}/api`).handler,
		listeners,
		clean() {
			for (const cleanup of cleanups.reverse()) cleanup?.();
		},
	};
}

async function until(predicate, attempts = 60) {
	for (let i = 0; i < attempts; i++) {
		if (predicate()) return true;
		await new Promise((resolve) => setTimeout(resolve, 1));
	}
	return predicate();
}

function frameOf(sse, marker) {
	const chunk = sse.chunks.find((entry) => entry.includes(marker));
	return chunk === undefined ? undefined : JSON.parse(chunk.slice(6)).frame;
}

async function getFile(route, path) {
	const req = new FakeRequest(`/m/api/files?path=${encodeURIComponent(path)}`);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	return res;
}

async function uploadFile(route, body) {
	const req = new FakeRequest("/m/api/files/upload", "POST");
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	queueMicrotask(() => {
		req.emit("data", Buffer.from(JSON.stringify(body)));
		req.emit("end");
	});
	await finished;
	return { statusCode: res.statusCode, body: res.chunks.length === 0 ? undefined : JSON.parse(res.chunks.at(-1)) };
}

function sseRequest(route) {
	const req = new FakeRequest("/m/api/events");
	const res = new FakeResponse();
	route(req, res);
	return res;
}

async function postJson(route, body) {
	const req = new FakeRequest("/m/api/respond", "POST");
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	queueMicrotask(() => {
		req.emit("data", Buffer.from(JSON.stringify(body)));
		req.emit("end");
	});
	await finished;
	return { status: res.statusCode, body: JSON.parse(res.chunks.at(-1)) };
}

test("question cancellation rejects with ASK_CANCELLED and survives SSE reconnect replay", async () => {
	const harness = createHarness();
	try {
		const route = harness.route;
		const sse = sseRequest(route);
		const answerer = harness.listeners.find((entry) => entry.event === "user-questions/request").fn;
		const pending = answerer({
			agent: { session: { id: "session-question" } },
			questions: [{ id: "q", question: "Continue?", options: [{ label: "yes" }] }],
		}, async () => {
			throw new Error("unexpected delegation");
		});
		const outcome = pending.then(
			() => ({ resolved: true }),
			(error) => ({ resolved: false, name: error.name, code: error.code }),
		);
		await new Promise((resolve) => setImmediate(resolve));
		const requested = JSON.parse(sse.chunks.find((chunk) => chunk.includes("question/requested")).slice(6));
		assert.equal(requested.type, "mobile/frame");
		assert.equal(requested.frame.type, "question/requested");

		sse.emit("close");
		const reconnected = sseRequest(route);
		assert.ok(reconnected.chunks.some((chunk) => chunk.includes(`\"rpcId\":\"${requested.frame.rpcId}\"`)));

		const response = await postJson(route, {
			kind: "cancel",
			rpcId: requested.frame.rpcId,
			sessionId: "session-question",
		});
		assert.deepEqual(response, { status: 200, body: { ok: true, accepted: true } });
		assert.deepEqual(await outcome, { resolved: false, name: "UserQuestionError", code: "ASK_CANCELLED" });
		assert.ok(reconnected.chunks.some((chunk) => chunk.includes("question/resolved")));

		const missingSession = await postJson(route, {
			kind: "cancel",
			rpcId: requested.frame.rpcId,
		});
		assert.equal(missingSession.status, 400);
		assert.equal(missingSession.body.error, "session-required");
	} finally {
		harness.clean();
	}
});

test("both-mode $events acknowledges an unhandled event when no phone is connected", async () => {
	const calls = [];
	let releaseStream;
	const gateway = {
		openWireStream(_endpoint, _payload, signal) {
			return (async function* () {
				yield { type: "ready", clientId: "client-1" };
				yield { type: "waterfall", event: "future/event", eventId: "event-1", agentId: "session:s", request: {} };
				await new Promise((resolve) => {
					releaseStream = resolve;
					signal.addEventListener("abort", resolve, { once: true });
				});
			})();
		},
		dispatchRpc(endpoint, payload) {
			calls.push({ endpoint, payload });
			return Promise.resolve({ ok: true, value: undefined });
		},
	};
	const harness = createHarness({ ...CONFIG, approvalMode: "both" }, { get: (name) => name === "typertGateway" ? gateway : undefined });
	try {
		for (let i = 0; i < 20 && calls.length === 0; i++) await new Promise((resolve) => setTimeout(resolve, 1));
		assert.deepEqual(calls, [{
			endpoint: "$events/result",
			payload: { args: { clientId: "client-1", eventId: "event-1", outcome: { kind: "next" } } },
		}]);
	} finally {
		harness.clean();
		releaseStream?.();
	}
});

test("download consumes an asynchronous stream error without crashing", async () => {
	const root = await mkdtemp(join(tmpdir(), "dsh-mobile-download-"));
	const file = join(root, "broken.txt");
	await writeFile(file, "not actually read");
	const probe = await open(file, "r");
	const fileHandlePrototype = Object.getPrototypeOf(probe);
	const originalCreateReadStream = fileHandlePrototype.createReadStream;
	fileHandlePrototype.createReadStream = function createBrokenStream() {
		return new Readable({
			read() {
				queueMicrotask(() => this.destroy(Object.assign(new Error("synthetic read failure"), { code: "EIO" })));
			},
		});
	};
	await probe.close();
	const harness = createHarness(CONFIG, {
		get: (name) => name === "workspaceRegistry" ? { list: () => [{ path: root }] } : undefined,
	});
	try {
		const req = new FakeRequest(`/m/api/files?path=${encodeURIComponent(file)}`);
		const res = new FakeResponse();
		const closed = new Promise((resolve) => res.once("close", resolve));
		harness.route(req, res);
		await closed;
		assert.equal(res.statusCode, 200);
		assert.equal(res.destroyed, true);
	} finally {
		fileHandlePrototype.createReadStream = originalCreateReadStream;
		harness.clean();
		await rm(root, { recursive: true, force: true });
	}
});

test("workspace file transfer rejects symlink escapes while still serving regular files", async () => {
	const root = await mkdtemp(join(tmpdir(), "dsh-mobile-root-"));
	const outside = await mkdtemp(join(tmpdir(), "dsh-mobile-outside-"));
	await writeFile(join(root, "inside.txt"), "inside");
	await writeFile(join(outside, "secret.txt"), "secret");
	await symlink(join(outside, "secret.txt"), join(root, "escape.txt"));
	await symlink(outside, join(root, "escape-dir"));
	const harness = createHarness(CONFIG, {
		get: (name) => name === "workspaceRegistry" ? { list: () => [{ path: root }] } : undefined,
	});
	try {
		const inside = await getFile(harness.route, join(root, "inside.txt"));
		assert.equal(inside.statusCode, 200);
		assert.equal(inside.chunks.join(""), "inside");

		for (const escape of [join(root, "escape.txt"), join(root, "escape-dir", "secret.txt"), join(outside, "secret.txt")]) {
			const blocked = await getFile(harness.route, escape);
			assert.equal(blocked.statusCode, 404, `blocked download for ${escape}`);
			assert.deepEqual(JSON.parse(blocked.chunks.at(-1)), { error: "file-not-found" });
		}

		const uploaded = await uploadFile(harness.route, { name: "fresh.txt", data: Buffer.from("fresh").toString("base64") });
		assert.equal(uploaded.statusCode, 200);
		assert.equal(await readFile(join(root, "fresh.txt"), "utf8"), "fresh");

		const duplicate = await uploadFile(harness.route, { name: "fresh.txt", data: Buffer.from("again").toString("base64") });
		assert.equal(duplicate.statusCode, 409);
		assert.equal(duplicate.body.error, "file-exists");

		const traversal = await uploadFile(harness.route, { name: "../leak.txt", data: Buffer.from("leak").toString("base64") });
		assert.equal(traversal.statusCode, 400);
		assert.equal(traversal.body.error, "invalid-name");
	} finally {
		harness.clean();
		await rm(root, { recursive: true, force: true });
		await rm(outside, { recursive: true, force: true });
	}
});

test("an aborted question signal releases the held waterfall with ASK_ABORTED", async () => {
	const harness = createHarness();
	try {
		sseRequest(harness.route);
		const answerer = harness.listeners.find((entry) => entry.event === "user-questions/request").fn;
		const controller = new AbortController();
		const pending = answerer({
			agent: { session: { id: "session-abort" } },
			questions: [{ id: "q", question: "Continue?", options: [{ label: "yes" }] }],
			signal: controller.signal,
		}, async () => ({ answers: [] }));
		const outcome = pending.then(
			() => ({ resolved: true }),
			(error) => ({ resolved: false, name: error.name, code: error.code }),
		);
		controller.abort();
		assert.deepEqual(await outcome, { resolved: false, name: "UserQuestionError", code: "ASK_ABORTED" });
	} finally {
		harness.clean();
	}
});

test("a disconnected $events stream drops remote pending cards instead of leaving stale phone cards", async () => {
	const calls = [];
	let endStream;
	const gateway = {
		openWireStream(_endpoint, _payload, signal) {
			return (async function* () {
				yield { type: "ready", clientId: "client-1" };
				yield {
					type: "waterfall",
					event: "user-questions/request",
					eventId: "event-remote",
					agentId: "session:remote",
					request: { questions: [{ id: "q", question: "Continue?", options: [{ label: "yes" }] }] },
				};
				await new Promise((resolve) => {
					endStream = resolve;
					signal.addEventListener("abort", resolve, { once: true });
				});
			})();
		},
		dispatchRpc(endpoint, payload) {
			calls.push({ endpoint, payload });
			return Promise.resolve({ ok: true, value: undefined });
		},
	};
	const harness = createHarness({ ...CONFIG, approvalMode: "both" }, {
		get: (name) => name === "typertGateway" ? gateway : undefined,
	});
	try {
		const sse = sseRequest(harness.route);
		assert.ok(await until(() => frameOf(sse, "question/requested") !== undefined), "phone receives the remote pending card");
		endStream?.();
		assert.ok(await until(() => sse.chunks.some((chunk) => chunk.includes("question/resolved"))), "disconnect clears the stale card");
		const resolved = frameOf(sse, "question/resolved");
		assert.equal(resolved.cancelled, true);
		assert.equal(resolved.questionRpcId, "event-remote");
		assert.deepEqual(calls, [], "a disconnected stream never attempts a settlement receipt");
	} finally {
		harness.clean();
		endStream?.();
	}
});
