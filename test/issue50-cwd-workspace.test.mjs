// issue #50：手机端在「未注册工作区」的目录新建会话 → 会话成为孤儿 → dsh 下次启动
// bootstrap 调 WorkspaceEntity.attachSession 时因 cwd ≠ 工作区根抛错 → fatal load failure。
//
// 覆盖外部可观察行为（服务端半边）：
//   - cwd 不属于任何已注册工作区时，建会话前会把它注册成工作区，并用工作区规范路径建会话；
//   - 会话随后能成功 attach 到该工作区（不再静默失败留下孤儿）；
//   - cwd 已属已注册工作区时复用，不重复注册；
//   - cwd 不是可用目录（create 抛错）→ 400 cwd-not-a-directory，且不创建会话；
//   - 旧宿主（registry 无 create）走原「向上找祖先工作区」路径且不改写 cwd。
import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

let apply;
let normalizeServerPath;
let testHome;

/** 夹具路径按宿主平台归一（插件内部同样走 normalizeServerPath，win32 下 `/` 会转成 `\`）。 */
const native = (p) => normalizeServerPath(p);

// 进程级持久化文件必须隔离，否则会读写开发者本机的 ~/.dsh/mobile-remote。
test.before(async () => {
	testHome = await mkdtemp(join(tmpdir(), "dsh-mobile-issue50-"));
	process.env.HOME = testHome;
	({ apply, normalizeServerPath } = await import("../lib/index.js"));
});

test.after(async () => {
	await rm(testHome, { recursive: true, force: true });
});

const CONFIG = {
	path: "/m",
	authToken: "1234567890123456",
	cookieName: "dsh_mobile_token",
	trustedHosts: [],
	sessionTtlMs: 60_000,
	rechargeUrl: "https://example.test/top-up",
	maxConnections: 4,
	warmUpOnStart: false,
	pushUrls: [],
	pushCooldownMs: 1,
	doneGraceMs: 1,
	pushContent: "minimal",
	rateLimit: {},
	lanBridge: { enabled: false, port: 3080, host: "127.0.0.1" },
	approvalMode: "mobile",
};

class FakeResponse extends EventEmitter {
	constructor() {
		super();
		this.headersSent = false;
		this.chunks = [];
	}
	writeHead(statusCode) {
		this.statusCode = statusCode;
		this.headersSent = true;
	}
	write(chunk) {
		this.chunks.push(Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk));
		return true;
	}
	end(chunk = "") {
		if (chunk !== "") this.chunks.push(String(chunk));
		this.writableEnded = true;
		this.emit("finish");
	}
	destroy() {
		this.destroyed = true;
		this.emit("close");
	}
}

class FakeRequest extends EventEmitter {
	constructor(url, method = "GET", body) {
		super();
		this.url = url;
		this.method = method;
		this.body = body;
		this.headers = {
			host: "127.0.0.1",
			"x-mobile-token": CONFIG.authToken,
			"content-type": "application/json",
			...(body === undefined ? {} : { "content-length": String(Buffer.byteLength(JSON.stringify(body))) }),
		};
		this.socket = { remoteAddress: "127.0.0.1" };
		this.complete = true;
		this.readable = true;
		this.destroyed = false;
	}
	on(event, handler) {
		if (event === "data" && this.body !== undefined) {
			setImmediate(() => handler(Buffer.from(JSON.stringify(this.body))));
		}
		if (event === "end") setImmediate(() => handler());
		return this;
	}
	pause() {}
}

/** 假工作区实体：attachSession 记录调用（真实内核会校验 cwd === 工作区根）。 */
const workspaceEntity = (path, attached) => ({
	path,
	async attachSession(sessionId) {
		attached.push({ path, sessionId });
	},
});

/**
 * 假工作区注册表。
 * @param registered 已注册工作区路径
 * @param createImpl 覆盖 create 行为（抛错用例注入）
 * @param omitCreate true = 模拟旧宿主（registry 没有 create）
 */
function makeRegistry({ registered = ["/root"], createImpl, omitCreate = false } = {}) {
	const attached = [];
	const created = [];
	const entities = new Map(registered.map((p) => [p, workspaceEntity(p, attached)]));
	const registry = {
		attached,
		created,
		list: () => [...entities.values()],
		resolveByPath: async (p) => entities.get(p),
	};
	if (!omitCreate) {
		registry.create =
			createImpl ??
			(async (p) => {
				if (entities.has(p)) return entities.get(p);
				created.push(p);
				const entity = workspaceEntity(p, attached);
				entities.set(p, entity);
				return entity;
			});
	}
	return registry;
}

/** 假宿主：只装建会话路径需要的服务。 */
function createHarness({ registry, agents } = {}) {
	const routes = [];
	const provided = new Map();
	const warnings = [];
	if (registry) provided.set("workspaceRegistry", registry);
	if (agents) provided.set("agents", agents);
	provided.set("agentPresets", {
		defaultId: "standard",
		resolve: async (id) => ({ id }),
		mount: async () => {},
	});
	// 0.2.x 形态（四参 invokeRpc）——apiRpc 按 arity 判代际
	provided.set("typertGateway", {
		async invokeRpc(endpoint, payload, signal, peer) {
			void payload; void signal; void peer;
			if (endpoint === "session/modelCatalog") {
				return { ok: true, value: { default: { provider: "deepseek", model: "deepseek-flash" } } };
			}
			return { ok: true, value: {} };
		},
	});
	const ctx = {
		webServer: {
			host: "127.0.0.1",
			port: 43120,
			register(spec) {
				routes.push(spec);
				return () => {};
			},
		},
		logger: {
			warn(...a) {
				warnings.push(a.join(" "));
			},
			info() {},
		},
		get(name) {
			return provided.get(name);
		},
		provide(name, value) {
			provided.set(name, value);
		},
		on() {
			return () => {};
		},
		effect(callback) {
			const disposer = callback?.();
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
	};
	const dispose = apply(ctx, CONFIG);
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		warnings,
		clean() {
			dispose?.();
		},
	};
}

const makeAgents = () => {
	const created = [];
	return {
		created,
		list: () => [],
		async create(args) {
			created.push(args);
			return { agent: { id: "agent-1", session: {} }, dispose: async () => {} };
		},
	};
};

async function createSession(route, body) {
	const req = new FakeRequest("/m/api/sessions", "POST", body);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", resolve));
	route(req, res);
	await finished;
	return { status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") };
}

test("#50 未注册工作区的 cwd：建会话前注册成工作区，并成功 attach（不再产生孤儿会话）", async () => {
	const registry = makeRegistry({ registered: [native("/root")] });
	const agents = makeAgents();
	const harness = createHarness({ registry, agents });
	try {
		const { status, body } = await createSession(harness.route, { cwd: "/root/deVirt" });
		assert.equal(status, 200);
		assert.equal(body.ok, true);

		// 注册发生且只发生一次
		assert.deepEqual(registry.created, [native("/root/deVirt")]);
		// 会话建在（规范化的）目标目录，而不是回落到 /root
		assert.equal(agents.created.length, 1);
		assert.equal(agents.created[0].meta.cwd, native("/root/deVirt"));
		// 归属工作区成功 attach —— 这正是防止下次启动 fatal 的关键
		assert.deepEqual(
			registry.attached.map((hit) => hit.path),
			[native("/root/deVirt")],
		);
		assert.equal(registry.attached[0].sessionId, body.sessionId);
	} finally {
		harness.clean();
	}
});

test("#50 已注册工作区的 cwd：复用既有工作区，不重复注册", async () => {
	const registry = makeRegistry({ registered: [native("/root"), native("/root/deVirt")] });
	const agents = makeAgents();
	const harness = createHarness({ registry, agents });
	try {
		const { status } = await createSession(harness.route, { cwd: "/root/deVirt" });
		assert.equal(status, 200);
		assert.deepEqual(registry.created, []);
		assert.deepEqual(
			registry.attached.map((hit) => hit.path),
			[native("/root/deVirt")],
		);
		assert.equal(agents.created[0].meta.cwd, native("/root/deVirt"));
	} finally {
		harness.clean();
	}
});

test("#50 不可用目录：返回 400 cwd-not-a-directory，且不创建会话", async () => {
	const registry = makeRegistry({
		registered: [native("/root")],
		createImpl: async () => {
			throw new Error("ENOENT: no such file or directory");
		},
	});
	const agents = makeAgents();
	const harness = createHarness({ registry, agents });
	try {
		const { status, body } = await createSession(harness.route, { cwd: "/root/nope-not-here" });
		assert.equal(status, 400);
		assert.equal(body.error, "cwd-not-a-directory");
		assert.equal(agents.created.length, 0);
		assert.deepEqual(registry.attached, []);
	} finally {
		harness.clean();
	}
});

test("#50 旧宿主（registry 无 create）：回落祖先工作区且不改写 cwd", async () => {
	const registry = makeRegistry({ registered: [native("/root")], omitCreate: true });
	const agents = makeAgents();
	const harness = createHarness({ registry, agents });
	try {
		const { status } = await createSession(harness.route, { cwd: "/root/deVirt" });
		assert.equal(status, 200);
		// 旧路径：仍然建在用户选的目录下，不做注册（仅做分隔符归一，win32 会转成 `\`）
		assert.equal(agents.created[0].meta.cwd, native("/root/deVirt"));
		assert.deepEqual(
			registry.attached.map((hit) => hit.path),
			[native("/root")],
		);
	} finally {
		harness.clean();
	}
});
