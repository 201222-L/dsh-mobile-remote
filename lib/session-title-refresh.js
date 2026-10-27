export const DEFAULT_TITLE_REFRESH_BUDGET_MS = 1500;
export const DEFAULT_TITLE_REFRESH_CONCURRENCY = 4;

/**
 * Coalesce title refreshes for one corpus pass.
 *
 * Why a pass folds in **one** host call (issue #20 review, 2026-10-07):
 * `sessionQuery.readTitleSnapshots(ids)` is not a point read. The installed
 * `0.2.0-rc.2` chain is
 *
 *     readTitleSnapshots → SessionCorpus.projectMany → listPersisted → persistence.list()
 *
 * and `persistence.list()` walks the whole corpus (per-file header + stat, plus
 * a corpus-wide revision hash while a historical generation is present). Batch
 * size therefore multiplies corpus enumerations: folding four ids at a time
 * cost ceil(N/4) full enumerations on top of the pass. The pass now hands every
 * pending id to one call, so the enumeration count stays constant as N grows;
 * read width inside that call is the host's own `persistedReadConcurrency`
 * (default 4, `SESSION_QUERY_DEFAULT_PERSISTED_INSPECT_CONCURRENCY`, bounded by
 * `projectMany`'s worker pool), and this module adds no per-id fan-out on top of
 * it. Only the plugin's own revision scan is bounded here — it reads no logs.
 *
 * Waiters may leave independently; the shared pass is cancelled only after its
 * last waiter leaves, unless a timed-out response promoted it to deliberate
 * background warm-up. A cancelled pass is retired immediately so the next
 * request starts a live successor instead of feeding the dead queue, while the
 * fold gate keeps a retired pass and its successor from overlapping — an
 * overlap would double the host's read width during cancellation cleanup.
 */
export const createSessionTitleRefresher = ({
	readRevision,
	readTitles,
	getCachedTitle,
	setCachedTitle,
	onCacheChange = () => {},
	concurrency = DEFAULT_TITLE_REFRESH_CONCURRENCY,
} = {}) => {
	if (typeof readTitles !== "function") throw new TypeError("readTitles must be a function");
	if (!Number.isSafeInteger(concurrency) || concurrency < 1) throw new RangeError("concurrency must be a positive safe integer");
	let currentRun = null;
	let disposed = false;
	// Serializes fold calls across runs: at most one host title call is in flight
	// per refresher, so cancellation cleanup cannot overlap fresh read work.
	let foldTail = Promise.resolve();

	const foldAll = (ids, signal) => {
		const previous = foldTail;
		let release;
		foldTail = new Promise((resolve) => { release = resolve; });
		return (async () => {
			try {
				if (signal.aborted) throw signal.reason ?? new Error("session title refresh aborted");
				await previous.catch(() => {});
				if (signal.aborted) throw signal.reason ?? new Error("session title refresh aborted");
				return await readTitles(ids, signal);
			} finally {
				release();
			}
		})();
	};

	const finishRun = (run) => {
		run.done = true;
		if (run.deadlineTimer) {
			clearTimeout(run.deadlineTimer);
			run.deadlineTimer = null;
		}
		if (currentRun === run) currentRun = null;
		run.resolve();
	};

	// issue #28 复核 2：**run 级**有限寿命（源级政策）。
	// 调用者级的 `backgroundOnBudget: false` 只约束「谁不提升」——挡不住后来加入的 HTTP 调用者
	// 在自己的响应预算到点时把 run 提升为**永久后台**；坏源一旦永生，之后健康的请求会一直 join 它
	// （只拿到短码），失败隔离就没有闭环。故把截止放在 run 上：到点即中止并退休，**不看 background**。
	const armRunDeadline = (run) => {
		if (!Number.isFinite(run.deadlineAt) || run.deadlineTimer) return;
		const remaining = Math.max(0, run.deadlineAt - performance.now());
		run.deadlineTimer = setTimeout(() => {
			run.deadlineTimer = null;
			if (run.done || run.controller.signal.aborted) return;
			run.controller.abort(new Error("session-title refresh run exceeded its deadline"));
			if (currentRun === run) currentRun = null;
		}, remaining);
		run.deadlineTimer.unref?.();
	};

	const processRun = async (run) => {
		const { signal } = run.controller;
		try {
			while (!disposed && !signal.aborted && run.queue.length > 0) {
				// Drain everything queued so far into this round: revisions first
				// (bounded workers, no log reads), then a single fold call.
				const pending = run.queue.splice(0, run.queue.length);
				const misses = [];
				let cursor = 0;
				const scanRevisions = async () => {
					for (;;) {
						if (disposed || signal.aborted) return;
						const index = cursor;
						cursor += 1;
						if (index >= pending.length) return;
						const id = pending[index];
						let revision = null;
						if (typeof readRevision === "function") {
							try {
								const observed = await readRevision(id, signal);
								revision = typeof observed === "string" && observed !== "" ? observed : null;
							} catch (error) {
								if (signal.aborted) throw error;
							}
						}
						if (disposed || signal.aborted) return;
						const cached = getCachedTitle?.(id, revision);
						if (cached?.hit) run.results.set(id, cached.title);
						else misses.push({ index, id, revision });
					}
				};
				await Promise.all(Array.from(
					{ length: Math.min(concurrency, pending.length) },
					() => scanRevisions(),
				));
				if (disposed || signal.aborted) break;
				// Worker completion order is not the request order; keep the fold
				// deterministic (and stable for the host's first-occurrence ordering).
				misses.sort((a, b) => a.index - b.index);

				if (misses.length > 0) {
					let folded;
					try {
						folded = await foldAll(misses.map(({ id }) => id), signal);
					} catch (error) {
						if (signal.aborted) throw error;
						folded = new Map();
					}
					if (disposed || signal.aborted) break;
					for (const { id, revision } of misses) {
						const result = folded?.get?.(id);
						if (!result?.ok) continue;
						const title = typeof result.title === "string" && result.title !== "" ? result.title : null;
						setCachedTitle?.(id, revision, title);
						run.results.set(id, title);
					}
				}
				onCacheChange();
			}
		} catch {
			// An aborted or faulty refresh is a cache miss, never an endpoint failure.
		} finally {
			finishRun(run);
		}
	};

	const addIds = (run, ids) => {
		for (const id of ids) {
			if (typeof id !== "string" || id === "" || run.seen.has(id)) continue;
			run.seen.add(id);
			run.queue.push(id);
		}
	};

	const createRun = (ids) => {
		let resolve;
		const promise = new Promise((done) => { resolve = done; });
		const run = {
			controller: new AbortController(),
			queue: [],
			seen: new Set(),
			results: new Map(),
			waiters: 0,
			background: false,
			deadlineAt: Infinity,
			deadlineTimer: null,
			done: false,
			promise,
			resolve,
		};
		addIds(run, ids);
		currentRun = run;
		void processRun(run);
		return run;
	};

	const refresh = async (ids, { signal, budgetMs = DEFAULT_TITLE_REFRESH_BUDGET_MS, backgroundOnBudget = true, runDeadlineMs } = {}) => {
		if (disposed || signal?.aborted) return new Map();
		const uniqueIds = [...new Set(ids)].filter((id) => typeof id === "string" && id !== "");
		if (uniqueIds.length === 0) return new Map();
		if (!Number.isFinite(budgetMs) || budgetMs < 0) throw new RangeError("budgetMs must be a non-negative finite number");

		// A run whose upstream was already aborted can no longer consume its queue:
		// joining it would park this request's ids in a dead queue and hand back a
		// partial result. Retire it and start a live successor instead; the fold
		// gate keeps the successor's work behind the retiring pass's cleanup.
		let run = currentRun;
		if (!run || run.done || run.controller.signal.aborted) run = createRun(uniqueIds);
		else addIds(run, uniqueIds);
		// issue #28 复核 2：run 级截止（取所有声明中**最早**者——只收紧、不放松）。
		// 它不因后来调用者的 background promotion 而失效：到点由 armRunDeadline 退休该 run。
		if (Number.isFinite(runDeadlineMs) && runDeadlineMs >= 0) {
			const nextAt = performance.now() + runDeadlineMs;
			// 只在**收紧**时重设：后来者更晚的声明不得延长期限（issue #28 复核 3）。
			if (nextAt < run.deadlineAt) {
				run.deadlineAt = nextAt;
				// 旧 timer 必须先清掉再重设——armRunDeadline 见到已有 deadlineTimer 会直接返回，
				// 那样「收紧」就静默失效（评审实测：先声明 300ms、后声明 20ms，源仍按 300ms 才取消）。
				if (run.deadlineTimer) {
					clearTimeout(run.deadlineTimer);
					run.deadlineTimer = null;
				}
				armRunDeadline(run);
			}
		}
		run.waiters += 1;
		let released = false;
		const release = () => {
			if (released) return;
			released = true;
			run.waiters -= 1;
			if (!run.done && !run.background && run.waiters === 0) {
				run.controller.abort(new Error("all session-title refresh waiters left"));
			}
		};

		let timer;
		let abortHandler;
		const interrupted = new Promise((resolve) => {
			if (signal) {
				abortHandler = () => resolve("aborted");
				signal.addEventListener("abort", abortHandler, { once: true });
			}
			timer = setTimeout(() => resolve("budget"), budgetMs);
		});
		const outcome = await Promise.race([
			run.promise.then(() => "done"),
			interrupted,
		]);
		clearTimeout(timer);
		if (signal && abortHandler) signal.removeEventListener("abort", abortHandler);

		// issue #28 复核 BLOCKING 2：调用方可以要求**有限生命期**。默认（响应路径）预算到点会把
		// run 提升为「后台预热」并长期存活；但启动预热**不能**这样——否则一次挂住的预热会让之后
		// 健康的请求一直 join 这个坏 run、只拿到短码。传 `backgroundOnBudget: false` 时不做提升，
		// 于是下面的 release() 在没有其它等待者时会中止该 run（退休），健康请求随后可重新开始。
		if (outcome === "budget" && backgroundOnBudget && !signal?.aborted && !run.done) run.background = true;
		const aborted = signal?.aborted === true;
		release();
		return aborted ? new Map() : new Map(run.results);
	};

	return {
		refresh,
		dispose() {
			disposed = true;
			currentRun?.controller.abort(new Error("session-title refresher disposed"));
		},
		/** Test seam: resolve when the current single-flight pass settles. */
		whenIdle() {
			return currentRun?.promise ?? Promise.resolve();
		},
	};
};
