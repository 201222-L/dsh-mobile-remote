import assert from "node:assert/strict";
import test from "node:test";

import { createSessionTitleRefresher } from "../lib/session-title-refresh.js";

const deferred = () => {
	let resolve;
	let reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
};

const waitFor = async (predicate, message) => {
	for (let i = 0; i < 100; i += 1) {
		if (predicate()) return;
		await new Promise((resolve) => setTimeout(resolve, 1));
	}
	assert.fail(message);
};

test("revision 命中复用持久化标题，变化后才折叠新日志", async () => {
	const stored = new Map([["a", { revision: "r1", title: "标题 A" }]]);
	let reads = 0;
	const refresher = createSessionTitleRefresher({
		readRevision: async (id) => id === "gone" ? null : "r1",
		readTitles: async (ids) => {
			reads += ids.length;
			return new Map(ids.map((id) => [id, { ok: true, title: `fresh ${id}` }]));
		},
		getCachedTitle: (id, revision) => {
			const entry = stored.get(id);
			return entry?.revision === revision ? { hit: true, title: entry.title } : { hit: false };
		},
		setCachedTitle: (id, revision, title) => stored.set(id, { revision, title }),
	});

	assert.deepEqual(await refresher.refresh(["a"]), new Map([["a", "标题 A"]]));
	assert.equal(reads, 0, "相同 revision 不得重读日志");
	stored.set("a", { revision: "r0", title: "过期标题" });
	assert.deepEqual(await refresher.refresh(["a"]), new Map([["a", "fresh a"]]));
	assert.equal(reads, 1, "revision 变化必须回源一次");
	refresher.dispose();
});

test("并发调用共享一个在途折叠；一个等待者取消不取消另一个", async () => {
	const started = deferred();
	const finishRevision = deferred();
	let revisionCalls = 0;
	let foldCalls = 0;
	let internalSignal;
	const refresher = createSessionTitleRefresher({
		readRevision: (_id, signal) => {
			revisionCalls += 1;
			internalSignal = signal;
			started.resolve();
			return new Promise((resolve, reject) => {
				signal.addEventListener("abort", () => reject(signal.reason), { once: true });
				finishRevision.promise.then(() => resolve("r1"), reject);
			});
		},
		readTitles: async (ids) => {
			foldCalls += 1;
			return new Map(ids.map((id) => [id, { ok: true, title: `标题 ${id}` }]));
		},
	});
	const firstAbort = new AbortController();
	const secondAbort = new AbortController();
	const first = refresher.refresh(["shared"], { signal: firstAbort.signal, budgetMs: 1000 });
	await started.promise;
	const second = refresher.refresh(["shared"], { signal: secondAbort.signal, budgetMs: 1000 });
	firstAbort.abort(new Error("first client disconnected"));
	assert.deepEqual(await first, new Map());
	assert.equal(internalSignal.aborted, false, "另一等待者仍在等时不得取消共享工作");
	finishRevision.resolve();
	assert.deepEqual(await second, new Map([["shared", "标题 shared"]]));
	assert.equal(revisionCalls, 1, "并发请求不得重复 stat");
	assert.equal(foldCalls, 1, "并发请求不得重复标题折叠");
	refresher.dispose();
});

test("最后一个 HTTP 等待者断开会取消在途读取", async () => {
	const started = deferred();
	let sourceAborted = false;
	const refresher = createSessionTitleRefresher({
		readRevision: (_id, signal) => new Promise((resolve, reject) => {
			started.resolve();
			signal.addEventListener("abort", () => {
				sourceAborted = true;
				reject(signal.reason);
			}, { once: true });
		}),
		readTitles: async () => new Map(),
	});
	const request = new AbortController();
	const result = refresher.refresh(["only"], { signal: request.signal, budgetMs: 1000 });
	await started.promise;
	request.abort(new Error("client disconnected"));
	assert.deepEqual(await result, new Map());
	await refresher.whenIdle();
	assert.equal(sourceAborted, true, "没人等待时应把取消传到上游 stat");
	refresher.dispose();
});

test("响应预算到期后保留共享工作作为后台预热", async () => {
	const started = deferred();
	const finishRevision = deferred();
	let sourceAborted = false;
	let folds = 0;
	const refresher = createSessionTitleRefresher({
		readRevision: (_id, signal) => new Promise((resolve, reject) => {
			started.resolve();
			signal.addEventListener("abort", () => {
				sourceAborted = true;
				reject(signal.reason);
			}, { once: true });
			finishRevision.promise.then(() => resolve("r1"), reject);
		}),
		readTitles: async (ids) => {
			folds += ids.length;
			return new Map(ids.map((id) => [id, { ok: true, title: `标题 ${id}` }]));
		},
	});
	const result = await refresher.refresh(["warm"], { budgetMs: 10 });
	assert.deepEqual(result, new Map(), "未完成的标题应允许短码兜底");
	await started.promise;
	assert.equal(sourceAborted, false, "预算到期是后台预热，不等同于客户端断开");
	finishRevision.resolve();
	await refresher.whenIdle();
	assert.equal(folds, 1, "后台预热应补齐标题");
	refresher.dispose();
});

test("revision 扫描受四路上限约束；整轮 miss 只发一次批量折叠", async () => {
	let active = 0;
	let maxActive = 0;
	const enter = async (work) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		try {
			await new Promise((resolve) => setTimeout(resolve, 2));
			return await work();
		} finally {
			active -= 1;
		}
	};
	const folds = [];
	const refresher = createSessionTitleRefresher({
		readRevision: (id) => enter(() => `r-${id}`),
		readTitles: async (ids) => {
			folds.push([...ids]);
			return new Map(ids.map((id) => [id, { ok: true, title: id }]));
		},
		concurrency: 4,
	});
	const ids = Array.from({ length: 17 }, (_, i) => `s-${i}`);
	const result = await refresher.refresh(ids, { budgetMs: 1000 });
	assert.equal(result.size, ids.length);
	assert.ok(maxActive <= 4, `observed ${maxActive} concurrent revision reads`);
	// 宿主 readTitleSnapshots 每次调用都会全量枚举语料（projectMany → persistence.list），
	// 所以整轮只能发一次；批次数不得随 N 增长。
	assert.equal(folds.length, 1, `expected one fold call per pass, saw ${folds.length}`);
	assert.deepEqual(folds[0], ids, "the single fold call must carry every pending id");
	refresher.dispose();
});

test("已 abort 但未结束的 run 不复用：新请求进入后继任务且关闭前不叠加折叠", async () => {
	const firstFoldStarted = deferred();
	const finishRetiredFold = deferred();
	let concurrentFolds = 0;
	let maxConcurrentFolds = 0;
	const foldBatches = [];
	const reads = [];
	const refresher = createSessionTitleRefresher({
		readRevision: async (id) => {
			reads.push(id);
			return `r-${id}`;
		},
		readTitles: async (ids, signal) => {
			foldBatches.push([...ids]);
			concurrentFolds += 1;
			maxConcurrentFolds = Math.max(maxConcurrentFolds, concurrentFolds);
			try {
				if (foldBatches.length === 1) {
					firstFoldStarted.resolve();
					// 上游已被 abort，但取消清理尚未结束：本次调用仍然挂着。
					await finishRetiredFold.promise;
				}
				return new Map(ids.map((id) => [id, { ok: true, title: `标题 ${id}（signal=${signal?.aborted ? "aborted" : "live"}）` }]));
			} finally {
				concurrentFolds -= 1;
			}
		},
	});

	const firstClient = new AbortController();
	const retired = refresher.refresh(["old"], { signal: firstClient.signal, budgetMs: 1000 });
	await firstFoldStarted.promise;
	firstClient.abort(new Error("client disconnected"));
	assert.deepEqual(await retired, new Map());

	const retry = refresher.refresh(["old", "new"], { budgetMs: 1000 });
	await new Promise((resolve) => setImmediate(resolve));
	assert.equal(foldBatches.length, 1, "取消清理期间不得叠加第二轮折叠（并发上限必须保持）");

	finishRetiredFold.resolve();
	const retryTitles = await retry;
	assert.deepEqual(foldBatches[1], ["old", "new"], "重试必须折叠新 id，而不是把新 id 放进死队列");
	assert.equal(retryTitles.get("new"), "标题 new（signal=live）", "重试必须拿回结果，不能只返回旧队列的部分结果");
	assert.equal(maxConcurrentFolds, 1, `observed ${maxConcurrentFolds} concurrent folds`);
	await refresher.whenIdle();
	assert.ok(reads.length >= 2, "后继任务必须重新读取 revision");
	refresher.dispose();
});

// issue #28 复核 3：`runDeadlineMs` 是 run 级政策，声称「取所有声明中最早者」——
// 但 armRunDeadline 见到已有 deadlineTimer 会直接返回，若收紧时不先清旧 timer，收紧会静默失效。
const hangingRevision = (state) => (_id, signal) => {
	state.signal = signal;
	return new Promise((_resolve, reject) => {
		signal.addEventListener("abort", () => reject(signal.reason), { once: true });
	});
};

test("共享 run 的截止只收紧：后来者更短的截止必须生效（issue #28 复核 3）", async () => {
	const state = { signal: null };
	const refresher = createSessionTitleRefresher({
		readRevision: hangingRevision(state),
		readTitles: async () => new Map(),
	});
	const startedAt = Date.now();
	void refresher.refresh(["a"], { budgetMs: 10_000, runDeadlineMs: 300 });
	await new Promise((resolve) => setTimeout(resolve, 30));
	void refresher.refresh(["b"], { budgetMs: 10_000, runDeadlineMs: 20 }); // 后来者更短：必须收紧
	await waitFor(() => state.signal?.aborted === true, "更短的截止未生效：源未被取消");
	assert.ok(Date.now() - startedAt < 250, `应在收紧后的截止附近取消（实测 ${Date.now() - startedAt}ms）`);
	refresher.dispose();
});

test("共享 run 的截止不得被后来者延长（issue #28 复核 3）", async () => {
	const state = { signal: null };
	const refresher = createSessionTitleRefresher({
		readRevision: hangingRevision(state),
		readTitles: async () => new Map(),
	});
	const startedAt = Date.now();
	void refresher.refresh(["a"], { budgetMs: 10_000, runDeadlineMs: 120 });
	await new Promise((resolve) => setTimeout(resolve, 30));
	void refresher.refresh(["b"], { budgetMs: 10_000, runDeadlineMs: 5_000 }); // 后来者更长：不得延长
	await waitFor(() => state.signal?.aborted === true, "原截止被延长：源未按最早截止取消");
	assert.ok(Date.now() - startedAt < 400, `应按最早的截止取消（实测 ${Date.now() - startedAt}ms）`);
	refresher.dispose();
});

test("run 正常完成后清理截止计时器：不得留下迟到取消（issue #28 复核 3）", async () => {
	const state = { signal: null };
	const refresher = createSessionTitleRefresher({
		readRevision: (_id, signal) => {
			state.signal = signal;
			return "r1";
		},
		readTitles: async (ids) => new Map(ids.map((id) => [id, { ok: true, title: `t-${id}` }])),
	});
	await refresher.refresh(["a"], { budgetMs: 500, runDeadlineMs: 60 });
	assert.equal(state.signal?.aborted, false, "正常完成时不得取消信号");
	await new Promise((resolve) => setTimeout(resolve, 150)); // 越过原截止
	assert.equal(state.signal?.aborted, false, "完成后不得留下迟到的取消");
	refresher.dispose();
});
