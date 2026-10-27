import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { zstdDecompressSync } from "node:zlib";
import test from "node:test";

import { LARGE_FIXTURE_BYTES, writeSessionCorpusFixtures, writeSessionLogFixture } from "./helpers/session-log-fixtures.mjs";

let apply;
let testHome;

test.before(async () => {
	testHome = await mkdtemp(join(tmpdir(), "dsh-session-title-refresh-home-"));
	process.env.HOME = testHome;
	({ apply } = await import("../lib/index.js"));
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
	// issue #28：预热默认开启；无关用例一律显式关掉，避免 1 秒后自动跑的预热打乱计数断言。
	warmUpOnStart: false,
	pushUrls: [],
	pushCooldownMs: 1,
	doneGraceMs: 1,
	pushContent: "minimal",
	rateLimit: {},
	lanBridge: { enabled: false, port: 3080, host: "127.0.0.1" },
	approvalMode: "mobile",
};

const deferred = () => {
	let resolve;
	let reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
};

const waitFor = async (predicate, message, timeoutMs = 10_000) => {
	const deadline = performance.now() + timeoutMs;
	while (performance.now() < deadline) {
		if (await predicate()) return;
		await new Promise((resolve) => setTimeout(resolve, 5));
	}
	assert.fail(typeof message === "function" ? message() : message);
};

const delay = (ms, signal) => new Promise((resolve, reject) => {
	if (signal?.aborted) return reject(signal.reason);
	const timer = setTimeout(done, ms);
	function done() {
		signal?.removeEventListener("abort", aborted);
		resolve();
	}
	function aborted() {
		clearTimeout(timer);
		signal?.removeEventListener("abort", aborted);
		reject(signal.reason);
	}
	signal?.addEventListener("abort", aborted, { once: true });
});

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
	constructor(url) {
		super();
		this.url = url;
		this.method = "GET";
		this.headers = { host: "127.0.0.1", "x-mobile-token": CONFIG.authToken };
		this.socket = { remoteAddress: "127.0.0.1" };
		this.complete = true;
		this.readable = true;
		this.destroyed = false;
	}
}

const parseFixtureTitle = (raw, fixture) => {
	const plaintextFrames = [];
	let offset = 0;
	for (const frameLength of fixture.frameLengths) {
		const end = offset + frameLength;
		plaintextFrames.push(zstdDecompressSync(raw.subarray(offset, end)));
		offset = end;
	}
	assert.equal(offset, raw.byteLength, `fixture ${fixture.id} frame index must cover its artifact`);
	const rows = Buffer.concat(plaintextFrames).toString("utf8").trimEnd().split("\n").map((line) => JSON.parse(line));
	const header = rows[0];
	const titleEvent = rows.findLast((row) => row.type === "session/title");
	return { header, title: titleEvent?.data?.title ?? null };
};

function createHarness(fixtures, {
	statDelayMs = () => 0,
	revisionListDelayMs = () => 0,
	listDelayMs = () => 0,
	listNeverSettles = false,
	beforeTitleRead,
	config = {},
	persistenceRoot = fixtures[0]?.root,
	persistenceName = "session-persistence-jsonl",
	persistenceCompression = "zstd",
} = {}) {
	const routes = [];
	const handlers = [];
	const logs = [];
	const fixtureById = new Map(fixtures.map((fixture) => [fixture.id, fixture]));
	const historicalRevision = createHash("sha256")
		.update(fixtures.map(({ file, sizeBytes }) => `${file}\\0${sizeBytes}`).sort().join("\\n"))
		.digest("hex");
	const records = fixtures.map((fixture) => ({
		header: { ...fixture.header },
		live: false,
		persisted: true,
	}));
	const listCalls = { count: 0 };
	const revisionLists = { count: 0 };
	const statCalls = { ids: new Set(), revisions: new Map() };
	const readCalls = {
		batches: 0,
		sessions: 0,
		ids: [],
		titles: new Map(),
		aborted: 0,
		signals: [],
		// 真实宿主的 readTitleSnapshots 不是点读：projectMany → listPersisted →
		// persistence.list() 每次调用都枚举整个语料。这里如实例演并单独计数，
		// 以便断言"整条调用链的枚举数不随 N 增长"。
		corpusListings: 0,
		inFlight: 0,
		maxInFlight: 0,
	};
	const provided = new Map();
	const sessions = new Map();
	provided.set("sessions", { get: (id) => sessions.get(id), list: () => [...sessions.values()] });
	const persistenceSnapshot = async (id, signal) => {
		signal?.throwIfAborted();
		const fixture = fixtureById.get(id);
		if (!fixture) return undefined;
		const statDelay = statDelayMs();
		if (statDelay > 0) await delay(statDelay, signal);
		const metadata = await stat(fixture.file, { bigint: true });
		signal?.throwIfAborted();
		const fileRevision = [metadata.dev, metadata.ino, metadata.size, metadata.mtimeNs, metadata.ctimeNs].join(":");
		const revision = fixture.version === 3 ? `${fileRevision}:${historicalRevision}` : fileRevision;
		statCalls.ids.add(id);
		statCalls.revisions.set(id, revision);
		return { header: fixture.header, revision, sizeBytes: Number(metadata.size) };
	};
	/** 一次完整语料枚举（与宿主 persistence.list 同语义）。 */
	const listCorpus = async (signal) => {
		const listingDelay = revisionListDelayMs();
		if (listingDelay > 0) await delay(listingDelay, signal);
		const snapshots = [];
		for (const fixture of fixtures) {
			const snapshot = await persistenceSnapshot(fixture.id, signal);
			if (snapshot) snapshots.push(snapshot);
		}
		return snapshots;
	};
	provided.set("sessionPersistence", {
		name: persistenceName,
		config: { root: persistenceRoot, compression: persistenceCompression },
		async list({ signal } = {}) {
			revisionLists.count += 1;
			return listCorpus(signal);
		},
		async stat(id, { signal } = {}) {
			return persistenceSnapshot(id, signal);
		},
	});
	provided.set("sessionQuery", {
		async listSessions(signal) {
			listCalls.count += 1;
			signal?.throwIfAborted();
			if (listNeverSettles) return new Promise(() => {});
			const listingDelay = listDelayMs();
			if (listingDelay > 0) await delay(listingDelay, signal);
			return records;
		},
		async readTitleSnapshots(ids, signal) {
			readCalls.batches += 1;
			readCalls.signals.push(signal);
			readCalls.corpusListings += 1;
			readCalls.inFlight += 1;
			readCalls.maxInFlight = Math.max(readCalls.maxInFlight, readCalls.inFlight);
			try {
				await listCorpus(signal);
				await beforeTitleRead?.(ids, signal);
				const results = new Array(ids.length);
				let cursor = 0;
				// 宿主 projectMany 自己的有界 worker（persistedReadConcurrency 默认 4）：
				// 插件只发一次调用，宽度由宿主决定。
				const worker = async () => {
					for (;;) {
						signal?.throwIfAborted();
						const index = cursor;
						cursor += 1;
						if (index >= ids.length) return;
						const id = ids[index];
						const fixture = fixtureById.get(id);
						if (!fixture) {
							results[index] = { sessionId: id, status: "rejected" };
							continue;
						}
						const raw = await readFile(fixture.file, { signal });
						signal?.throwIfAborted();
						readCalls.sessions += 1;
						readCalls.ids.push(id);
						const parsed = parseFixtureTitle(raw, fixture);
						readCalls.titles.set(id, parsed.title);
						results[index] = {
							sessionId: id,
							status: "fulfilled",
							value: {
								session: parsed.header,
								...(parsed.title ? { title: { title: parsed.title } } : {}),
							},
						};
					}
				};
				await Promise.all(Array.from({ length: Math.min(4, ids.length) }, worker));
				return results;
			} catch (error) {
				if (signal?.aborted) readCalls.aborted += 1;
				throw error;
			} finally {
				readCalls.inFlight -= 1;
			}
		},
	});
	const ctx = {
		webServer: { host: "127.0.0.1", port: 43120, register(spec) { routes.push(spec); return () => {}; } },
		logger: { warn(...args) { logs.push(args.join(" ")); }, info() {} },
		get(name) { return provided.get(name); },
		provide(name, value) { provided.set(name, value); },
		on(event, handler) { handlers.push([event, handler]); return () => {}; },
		effect(callback) {
			const disposer = callback?.();
			return typeof disposer === "function" ? disposer : () => {};
		},
		inject() {},
	};
	const dispose = apply(ctx, { ...CONFIG, ...config });
	return {
		route: routes.find((route) => route.path === "/m/api").handler,
		records,
		listCalls,
		revisionLists,
		statCalls,
		readCalls,
		logs,
		/** 模拟"请求进行中桌面端新建了会话"：语料与枚举结果同时出现新会话。 */
		addFixture(fixture) {
			fixtureById.set(fixture.id, fixture);
			fixtures.push(fixture);
			records.push({ header: { ...fixture.header }, live: false, persisted: true });
		},
		/** 整条调用链的语料枚举次数（枚举结果本身 + 标题批量接口内部的枚举）。 */
		corpusListings: () => listCalls.count + revisionLists.count + readCalls.corpusListings,
		clean() { dispose?.(); },
	};
}

function startRequest(route, url = "/m/api/sessions") {
	const req = new FakeRequest(url);
	const res = new FakeResponse();
	const finished = new Promise((resolve) => res.once("finish", () => {
		resolve({ status: res.statusCode, body: JSON.parse(res.chunks.join("") || "{}") });
	}));
	route(req, res);
	return { req, res, finished };
}

const request = async (route, url) => startRequest(route, url).finished;

test("真实 V3/V4 日志与 20 MiB 会话：首屏有界，预热后重启仍命中且不重读日志", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-real-logs-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 28, largePayloadBytes: LARGE_FIXTURE_BYTES });
	const large = fixtures.find((fixture) => fixture.id === "fixture-large-v4");
	assert.ok(large.sizeBytes >= LARGE_FIXTURE_BYTES, `large fixture has ${large.sizeBytes} bytes`);
	assert.ok(fixtures.some((fixture) => fixture.version === 3));
	assert.ok(fixtures.some((fixture) => fixture.version === 4));
	harness = createHarness(fixtures);
	const startedAt = performance.now();
	const first = await request(harness.route);
	const elapsedMs = performance.now() - startedAt;
	assert.equal(first.status, 200);
	assert.equal(first.body.sessions.length, fixtures.length, "partial title work must not truncate the session list");
	assert.ok(elapsedMs < 2000, `first response took ${elapsedMs.toFixed(1)} ms`);
	await waitFor(() => harness.readCalls.sessions === fixtures.length, "background warm-up did not finish all fixture logs");
	await new Promise((resolve) => setImmediate(resolve)); // let the coordinator commit the final batch result
	assert.equal(harness.readCalls.sessions, fixtures.length, "each cold title log is read once");
	assert.equal(harness.revisionLists.count, 1, "one corpus revision listing must serve the whole refresh pass");
	assert.equal(harness.readCalls.titles.get(large.id), large.title, "fixture reader must extract the large log title");
	assert.ok(harness.statCalls.revisions.get(large.id), "large session must produce a usable revision");
	const cachePath = join(home, ".dsh", "mobile-remote", "session-titles.json");
	let cachedIds = [];
	await waitFor(async () => {
		try {
			const current = JSON.parse(await readFile(cachePath, "utf8"));
			cachedIds = Object.keys(current.entries);
			return current.entries[large.id]?.title === large.title;
		} catch {
			return false;
		}
	}, () => `large title was not durably flushed; ids=${cachedIds.join(",")} revision=${harness.statCalls.revisions.get(large.id)}`);
	harness.clean(); // flush the persistent cache before simulating a host restart
	harness = null;
	const persisted = JSON.parse(await readFile(cachePath, "utf8"));
	assert.equal(persisted.entries[large.id]?.title, large.title, `large-session title missing; cached ids: ${Object.keys(persisted.entries).join(",")}`);

	harness = createHarness(fixtures);
	const second = await request(harness.route);
	assert.equal(second.status, 200);
	assert.equal(second.body.sessions.length, fixtures.length);
	const byId = new Map(second.body.sessions.map((row) => [row.id, row]));
	for (const fixture of fixtures) assert.equal(byId.get(fixture.id)?.title, fixture.title, `title for ${fixture.id}`);
	assert.equal(harness.readCalls.sessions, 0, `same revisions after restart must not trigger new log reads: ${harness.readCalls.ids.join(",")}`);
	assert.equal(harness.revisionLists.count, 1, "all revision reads on a refresh pass use one snapshot listing");
	harness.clean();
	harness = null;

	const changedFixture = writeSessionLogFixture(root, {
		id: "fixture-1",
		version: 4,
		title: "Changed V4 title",
		createdAt: fixtures.find((fixture) => fixture.id === "fixture-1").header.createdAt,
	});
	const changedFixtures = fixtures.map((fixture) => fixture.id === changedFixture.id ? changedFixture : fixture);
	harness = createHarness(changedFixtures);
	const changed = await request(harness.route);
	const changedById = new Map(changed.body.sessions.map((row) => [row.id, row]));
	assert.equal(changedById.get(changedFixture.id)?.title, changedFixture.title);
	assert.equal(
		harness.readCalls.sessions,
		fixtures.filter((fixture) => fixture.version === 3).length + 1,
		"V3's corpus-wide revision conservatively invalidates old titles, plus the changed V4 session",
	);
	harness.clean();
	harness = null;
});

test("354 个 V3/V4 会话冷请求仍完整返回且只取一次批量 revision 快照", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-scale-354-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 353, largePayloadBytes: 0 });
	assert.equal(fixtures.length, 354);
	harness = createHarness(fixtures);
	const startedAt = performance.now();
	const result = await request(harness.route);
	const elapsedMs = performance.now() - startedAt;
	assert.equal(result.status, 200);
	assert.equal(result.body.sessions.length, 354, "cold title folding must not truncate the corpus response");
	assert.ok(elapsedMs < 2000, `354-session response took ${elapsedMs.toFixed(1)} ms`);
	await waitFor(() => harness.readCalls.sessions === fixtures.length, "354-session background warm-up did not finish");
	assert.equal(harness.revisionLists.count, 1, "all session revisions must come from one bulk snapshot");
});

test("跨重启标题缓存按 JSONL 根目录隔离", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-root-scope-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 2, largePayloadBytes: 0 });
	harness = createHarness(fixtures);
	await request(harness.route);
	harness.clean();
	harness = null;

	harness = createHarness(fixtures, { persistenceRoot: join(root, "other-store") });
	const result = await request(harness.route);
	assert.equal(result.status, 200);
	assert.equal(harness.readCalls.sessions, fixtures.length, "a different JSONL root must not reuse another store's opaque revisions");
	harness.clean();
	harness = null;

	harness = createHarness(fixtures, { persistenceName: "unknown-session-persistence" });
	const unsupported = await request(harness.route);
	assert.equal(unsupported.status, 200);
	assert.equal(harness.readCalls.sessions, fixtures.length, "unknown providers must not reuse opaque tokens across restarts");
	harness.clean();
	harness = null;
});

test("/sessions 标题预算包含完整语料枚举耗时", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-list-budget-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 20, largePayloadBytes: 0 });
	harness = createHarness(fixtures, {
		listDelayMs: () => 900,
		revisionListDelayMs: () => 1400,
	});
	const startedAt = performance.now();
	const result = await request(harness.route);
	const elapsedMs = performance.now() - startedAt;
	assert.equal(result.status, 200);
	assert.equal(result.body.sessions.length, fixtures.length);
	assert.ok(elapsedMs < 2000, `list + bounded title wait took ${elapsedMs.toFixed(1)} ms`);
});

test("/subagents 标题预算同样包含完整语料枚举耗时", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-subagent-budget-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 20, largePayloadBytes: 0 });
	harness = createHarness(fixtures, {
		listDelayMs: () => 900,
		revisionListDelayMs: () => 1400,
	});
	for (const record of harness.records.slice(1)) {
		record.header.origin = "subagent";
		record.header.parentSession = fixtures[0].id;
	}
	const startedAt = performance.now();
	const result = await request(harness.route, `/m/api/subagents?parentSessionId=${encodeURIComponent(fixtures[0].id)}`);
	const elapsedMs = performance.now() - startedAt;
	assert.equal(result.status, 200);
	assert.equal(result.body.subagents.length, fixtures.length - 1);
	assert.ok(elapsedMs < 2000, `subagent enumeration + title wait took ${elapsedMs.toFixed(1)} ms`);
});

test("语料枚举超过**枚举预算**时 /sessions 与 /subagents 明确返回超时", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-enumeration-timeout-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 2, largePayloadBytes: 0 });
	// issue #27：枚举有**自己的**预算（不再借用 1.5s 标题预算），这里把它压小以便快速复现超时。
	const smallBudget = { config: { enumerationBudgetMs: 300 } };
	harness = createHarness(fixtures, { listNeverSettles: true, ...smallBudget });
	let startedAt = performance.now();
	let result = await request(harness.route);
	assert.equal(result.status, 504);
	assert.equal(result.body.error, "sessions-timeout");
	assert.ok(performance.now() - startedAt < 2000, "slow /sessions enumeration must not hang the sole entry point");
	harness.clean();
	harness = createHarness(fixtures, { listDelayMs: () => 5_000, ...smallBudget });
	startedAt = performance.now();
	result = await request(harness.route, `/m/api/subagents?parentSessionId=${encodeURIComponent(fixtures[0].id)}`);
	assert.equal(result.status, 504);
	assert.equal(result.body.error, "subagents-timeout");
	assert.ok(performance.now() - startedAt < 2000, "slow persisted subagent enumeration must fail clearly too");
});

test("冷启动枚举慢于标题预算、但快于枚举预算时 /sessions 仍返回 200 + N（issue #27）", async (t) => {
	// issue #27：宿主刚重启时内核语料是冷的（note 793 实测全量 stat 约 22 秒），枚举必然超过
	// 1.5s 的**标题**预算。此前枚举被标题预算掐断 → 冷启动首次请求直接 504、用户拿不到列表；
	// 现在枚举用**自己的**预算，必须返回 200 + N（标题可以是短码，随后后台预热）。
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-enumeration-budget-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 6, largePayloadBytes: 0 });
	harness = createHarness(fixtures, {
		// 1.7s：慢于标题预算（1500ms），快于**默认**枚举预算（12s）。刻意**不传** config——
		// 这条同时钉住真实部署路径：宿主 config 里没有 enumerationBudgetMs 字段时，
		// 必须回落到 DEFAULT_ENUMERATION_BUDGET_MS（防御性默认），而不是 NaN → 立即 504。
		listDelayMs: () => 1_700,
	});
	const startedAt = performance.now();
	const result = await request(harness.route);
	const elapsedMs = performance.now() - startedAt;
	assert.equal(result.status, 200, "枚举慢于标题预算时必须返回列表，而不是 504");
	assert.equal(result.body.sessions.length, fixtures.length);
	assert.ok(elapsedMs >= 1_700, `枚举应跑过标题预算（实测 ${elapsedMs.toFixed(1)} ms）`);
	// 标题预算已耗尽：休眠会话用短码兜底，不能为了标题把枚举再拖回去。
	const shortOf = (id) => (id.length > 12 ? `${id.slice(0, 8)}…${id.slice(-4)}` : id);
	for (const row of result.body.sessions) {
		assert.equal(row.title, shortOf(row.id), "标题预算耗尽后应使用短码兜底");
	}
});

test("并发 /sessions 共享同一标题折叠；一个客户端断开不取消另一个", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-concurrent-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 4, largePayloadBytes: 0 });
	const readStarted = deferred();
	const finishRead = deferred();
	let internalSignal;
	harness = createHarness(fixtures, {
		beforeTitleRead: async (_ids, signal) => {
			internalSignal = signal;
			readStarted.resolve();
			await new Promise((resolve, reject) => {
				if (signal.aborted) return reject(signal.reason);
				signal.addEventListener("abort", () => reject(signal.reason), { once: true });
				finishRead.promise.then(resolve, reject);
			});
		},
	});
	const first = startRequest(harness.route);
	await readStarted.promise;
	const second = startRequest(harness.route);
	await waitFor(() => harness.listCalls.count === 2, "second list request did not join");
	await new Promise((resolve) => setImmediate(resolve));
	first.res.destroy();
	assert.equal(internalSignal.aborted, false, "one disconnected waiter must not kill shared work");
	finishRead.resolve();
	const secondResult = await second.finished;
	assert.equal(secondResult.status, 200);
	assert.equal(secondResult.body.sessions.length, fixtures.length);
	assert.equal(harness.readCalls.batches, 1, "一轮折叠只发一次批量调用，且不随 HTTP 请求数增长");
	assert.equal(harness.readCalls.corpusListings, 1, "标题批量接口每次调用都会全量枚举语料，因此一轮只能调一次");
	assert.equal(harness.revisionLists.count, 1, "overlapping requests share one corpus revision snapshot");
	assert.equal(harness.readCalls.sessions, fixtures.length);
});

test("语料枚举次数不随会话数/标题批次增长（N 放大用例）", async (t) => {
	const counts = [];
	for (const count of [8, 40]) {
		const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
		const root = await mkdtemp(join(tmpdir(), `session-title-scale-${count}-`));
		process.env.HOME = home;
		let harness;
		try {
			const fixtures = writeSessionCorpusFixtures(root, { count: count - 1, largePayloadBytes: 0 });
			assert.equal(fixtures.length, count);
			harness = createHarness(fixtures);
			const result = await request(harness.route);
			assert.equal(result.status, 200);
			assert.equal(result.body.sessions.length, count);
			await waitFor(() => harness.readCalls.sessions === count, `N=${count} background warm-up did not finish`);
			assert.equal(harness.readCalls.batches, 1, `N=${count}: exactly one fold call serves the pass`);
			// 整条链：端点枚举 1 + 插件 revision 快照 1 + 标题批量接口内部枚举 1。
			counts.push(harness.corpusListings());
		} finally {
			harness?.clean();
			await rm(home, { recursive: true, force: true });
			await rm(root, { recursive: true, force: true });
		}
	}
	assert.deepEqual(counts, [3, 3], `corpus enumerations must not grow with N: ${counts.join(" vs ")}`);
});

test("最后一个 /sessions 等待者断开后取消上游标题读取", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-cancel-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 2, largePayloadBytes: 0 });
	const readStarted = deferred();
	let internalSignal;
	harness = createHarness(fixtures, {
		beforeTitleRead: async (_ids, signal) => {
			internalSignal = signal;
			readStarted.resolve();
			await new Promise((resolve, reject) => {
				if (signal.aborted) return reject(signal.reason);
				signal.addEventListener("abort", () => reject(signal.reason), { once: true });
				resolve();
			});
		},
	});
	const pending = startRequest(harness.route);
	await readStarted.promise;
	pending.res.destroy();
	await waitFor(() => internalSignal.aborted, "last request cancellation did not reach title read");
	await waitFor(() => harness.readCalls.aborted === 1, "aborted title read did not settle");
	assert.equal(harness.readCalls.sessions, 0, "no fixture event rows should be parsed after abort");
	assert.deepEqual(pending.res.chunks, [], "cancelled request must not write a response");
});

test("取消清理尚未结束时重试不复用死 run：新会话本次就被折叠", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-retire-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = [writeSessionLogFixture(root, { id: "old-session", version: 4, title: "旧会话标题" })];
	const firstFoldStarted = deferred();
	const finishRetiredFold = deferred();
	harness = createHarness(fixtures, {
		// 模拟"上游已 abort，但取消清理尚未 settle"：这次折叠会一直挂着，直到测试放行。
		beforeTitleRead: async () => {
			firstFoldStarted.resolve();
			await finishRetiredFold.promise;
		},
	});
	const pending = startRequest(harness.route);
	await firstFoldStarted.promise;
	pending.res.destroy();
	await waitFor(() => harness.readCalls.signals[0]?.aborted === true, "retired pass was not aborted");
	assert.equal(harness.listCalls.count, 1);

	// 桌面端在取消清理期间新建了会话，App 重试列表。
	const fresh = writeSessionLogFixture(root, {
		id: "fresh-session",
		version: 4,
		title: "新会话标题",
		createdAt: 1_700_000_000_500,
	});
	harness.addFixture(fresh);
	const retry = startRequest(harness.route);
	await waitFor(() => harness.listCalls.count === 2, "retry did not enumerate the corpus");
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(harness.readCalls.batches, 1, "取消清理期间不得叠加第二轮折叠（并发上限须保持）");

	finishRetiredFold.resolve();
	const retried = await retry.finished;
	assert.equal(retried.status, 200);
	const byId = new Map(retried.body.sessions.map((row) => [row.id, row]));
	assert.equal(
		byId.get("fresh-session")?.title,
		"新会话标题",
		"本次重试必须自己折叠新 id，而不是返回死队列的部分结果",
	);
	assert.equal(byId.get(fixtures[0].id)?.title, fixtures[0].title, "旧会话标题同样必须在本次重试里补齐");
	assert.equal(harness.readCalls.batches, 2, "后继任务在旧清理结束后才发自己的折叠调用");
	assert.equal(harness.readCalls.maxInFlight, 1, "任何时刻只允许一次在途折叠调用");
});

test("休眠父会话的子代理列表复用 revision 标题缓存", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-subagents-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 2, largePayloadBytes: 0 });
	harness = createHarness(fixtures);
	harness.records[1].header.origin = "subagent";
	harness.records[1].header.parentSession = fixtures[0].id;
	const result = await request(harness.route, `/m/api/subagents?parentSessionId=${encodeURIComponent(fixtures[0].id)}`);
	assert.equal(result.status, 200);
	assert.equal(result.body.parentAvailable, false);
	assert.equal(result.body.subagents.length, 1);
	assert.equal(result.body.subagents[0].title, fixtures[1].title);
	assert.equal(harness.readCalls.sessions, 1);
});

test("初始化预热（issue #28）：没有任何请求也会跑一遍枚举 + 标题折叠", async (t) => {
	// 冷路径会长时间占住事件循环（实测轻端点被推迟 8.48 秒），所以要在初始化后主动跑一遍
	// 与请求**同一条**路径，把冷代价挪到用户请求之前。
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-warmup-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 4, largePayloadBytes: 0 });
	harness = createHarness(fixtures, { config: { warmUpOnStart: true } });
	await new Promise((resolve) => setTimeout(resolve, 1_400)); // 预热延迟 1s + 余量
	assert.equal(harness.listCalls.count, 1, "初始化后应主动枚举一次语料（此间没有任何请求）");
	assert.equal(harness.readCalls.batches, 1, "预热应顺带折叠一轮标题（复用同一条路径）");
	// 预热之后发请求：结果不变，且标题命中缓存（不再重复折叠）
	const result = await request(harness.route);
	assert.equal(result.status, 200);
	assert.equal(result.body.sessions.length, fixtures.length);
	const byId = new Map(result.body.sessions.map((row) => [row.id, row]));
	for (const fixture of fixtures) {
		assert.equal(byId.get(fixture.id)?.title, fixture.title, "标题应来自语料（预热已折叠并缓存）");
	}
});

test("关闭预热（warmUpOnStart: false）：初始化后不发起任何枚举（issue #28）", async (t) => {
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-warmup-off-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 4, largePayloadBytes: 0 });
	harness = createHarness(fixtures, { config: { warmUpOnStart: false } });
	await new Promise((resolve) => setTimeout(resolve, 1_400));
	assert.equal(harness.listCalls.count, 0, "关闭预热后不得有任何枚举");
	assert.equal(harness.readCalls.batches, 0, "关闭预热后不得有任何标题折叠");
});

test("预热与请求重叠：共享同一次在途枚举，只枚举一次（issue #28 复核 BLOCKING 1）", async (t) => {
	// 评审实测：预热挂住时 HTTP 进入会各自 new controller、各发一次 listSessions（lists=2/maxActive=2）。
	// 修法是 owner 共享：请求必须加入预热那次在途枚举。
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-warmup-shared-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 4, largePayloadBytes: 0 });
	harness = createHarness(fixtures, {
		config: { warmUpOnStart: true },
		listDelayMs: () => 2_000, // 枚举很慢：保证 HTTP 请求到达时预热仍在途
	});
	await new Promise((resolve) => setTimeout(resolve, 1_100)); // 预热已启动、正卡在枚举里
	assert.equal(harness.listCalls.count, 1, "预热应已在途（场景前提）");
	const result = await request(harness.route);
	assert.equal(result.status, 200);
	assert.equal(result.body.sessions.length, fixtures.length);
	assert.equal(harness.listCalls.count, 1, "请求必须加入预热那次在途枚举，而不是再发一次全量枚举");
});

test("预热挂住后恢复：健康请求能重新读取真实标题（issue #28 复核 BLOCKING 2）", async (t) => {
	// 评审实测：预热 revision 扫描不 settle 时，之后的请求仍 join 旧 run（revisions=1/folds=0、
	// HTTP 200 仅短码）。修法是预热用**自己的有限生命期**且不提升为永久后台，到点退休坏 run。
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-warmup-hung-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 4, largePayloadBytes: 0 });
	let revisionListCalls = 0;
	harness = createHarness(fixtures, {
		// 预热自己的标题生命期压短，便于快速复现「预热挂住 → 到点退休」
		config: { warmUpOnStart: true, warmUpTitleBudgetMs: 300 },
		// 第一次 revision 扫描挂住（预热的），之后恢复健康（请求的）
		revisionListDelayMs: () => (revisionListCalls++ === 0 ? 60_000 : 0),
	});
	await new Promise((resolve) => setTimeout(resolve, 1_800)); // 预热启动 → 卡在 revision 扫描 → 到点退休
	const result = await request(harness.route);
	assert.equal(result.status, 200);
	const byId = new Map(result.body.sessions.map((row) => [row.id, row]));
	for (const fixture of fixtures) {
		assert.equal(
			byId.get(fixture.id)?.title,
			fixture.title,
			"健康请求必须重新折叠出真实标题，而不是沿用坏 run 的短码",
		);
	}
	assert.ok(harness.readCalls.batches >= 1, "请求应自己发起折叠");
});

test("预热挂起 + HTTP 先到响应预算：warm 截止仍须退休坏源（issue #28 复核 2）", async (t) => {
	// 评审复核 2 的窗口：HTTP 在 warm 期限**之前**加入，并先到自己的 1.5s 响应预算 → 它会把 run
	// 提升为**永久后台**；此时只有调用者级的 `backgroundOnBudget: false` 挡不住坏源永生。
	// 修法必须是 **run 级**硬截止：到点即中止并退休，不看 background。
	const home = await mkdtemp(join(tmpdir(), "session-title-refresh-home-"));
	const root = await mkdtemp(join(tmpdir(), "session-title-warmup-promotion-"));
	process.env.HOME = home;
	let harness;
	t.after(async () => {
		harness?.clean();
		await rm(home, { recursive: true, force: true });
		await rm(root, { recursive: true, force: true });
	});
	const fixtures = writeSessionCorpusFixtures(root, { count: 4, largePayloadBytes: 0 });
	let revisionListCalls = 0;
	harness = createHarness(fixtures, {
		config: { warmUpOnStart: true, warmUpTitleBudgetMs: 2_500 },
		// 第一次 revision 扫描挂住（预热的），之后恢复健康
		revisionListDelayMs: () => (revisionListCalls++ === 0 ? 60_000 : 0),
	});
	await new Promise((resolve) => setTimeout(resolve, 1_100)); // 预热已启动并卡在 revision 扫描
	const first = await request(harness.route); // HTTP 加入 → 自己的 1.5s 响应预算先到点 → run 被提升为后台
	assert.equal(first.status, 200);
	const firstTitles = new Map(first.body.sessions.map((row) => [row.id, row.title]));
	assert.equal(
		fixtures.filter((fixture) => firstTitles.get(fixture.id) === fixture.title).length,
		0,
		"场景前提：预热挂住时这一轮折叠不出来（只有短码）",
	);
	await new Promise((resolve) => setTimeout(resolve, 1_500)); // 严格等过 warm 截止（1.0s + 2.5s）
	const healthy = await request(harness.route); // provider 已健康 → 必须重新折叠
	assert.equal(healthy.status, 200);
	const healthyTitles = new Map(healthy.body.sessions.map((row) => [row.id, row.title]));
	for (const fixture of fixtures) {
		assert.equal(
			healthyTitles.get(fixture.id),
			fixture.title,
			"warm 截止退休坏源后，健康请求必须重新折叠出真实标题",
		);
	}
});
