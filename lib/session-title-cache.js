// issue #20 第 2 步（实现要点 1）：**revision 失效的持久化标题缓存**。
//
// 背景（见 issue #20 的 note 702 / 793）：
// - `/sessions` 在响应前同步折叠**全部休眠会话**的标题，而折叠要完整读取每个会话日志
//   （追加式多帧 zstd）——隔离实测冷缓存 68.2 s、生产 600 s 未返回。
// - 内核 `sessionQuery.observeSession(id)` 返回的 lease 带 `revision`（来自**不读日志**的
//   `persistence.stat()`）。revision 未变即意味着日志没变 → **可以零日志读取地复用标题**。
// - 但 `stat()` 本身也不便宜（实测 61.9 ms/会话 → 全量 354 个 21.9 s），所以本缓存
//   **必须同时有界**：条目数有界、每次请求的发散量有界（由调用方的时间预算控制）。
//
// 本模块只负责"存与取"，不做调度——预算与 single-flight 由调用方掌握。

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

/** 默认条目上限：约 1000 个会话足够覆盖常见语料，且文件体积可控（~100 KB 量级）。 */
export const DEFAULT_MAX_ENTRIES = 1000;

/**
 * @param {object} options
 * @param {string} options.file 落盘路径（`~/.dsh/mobile-remote/session-titles.json`）
 * @param {number} [options.maxEntries] 条目上限（超出按最久未更新淘汰）
 * @param {() => number} [options.now] 时间源（测试可注入）
 */
export const createTitleCache = ({ file, maxEntries = DEFAULT_MAX_ENTRIES, now = Date.now }) => {
	/** sessionId -> { title: string|null, revision: string, at: number } */
	const entries = new Map();
	let dirty = false;

	/**
	 * 读盘并替换当前内存快照。只接受 version 1；缺失/损坏/未知格式一律降级为空缓存，
	 * 缓存坏了不该让列表挂掉，也不能把不可信字段当成已确认的标题事实。
	 */
	const load = () => {
		entries.clear();
		dirty = false;
		try {
			if (!existsSync(file)) return;
			const parsed = JSON.parse(readFileSync(file, "utf8"));
			if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || parsed.version !== 1) return;
			const raw = parsed.entries;
			if (!raw || typeof raw !== "object" || Array.isArray(raw)) return;
			for (const [id, value] of Object.entries(raw)) {
				if (id === "") continue;
				if (!value || typeof value !== "object" || Array.isArray(value)) continue;
				if (typeof value.revision !== "string" || value.revision === "") continue;
				// 只有显式 null 才代表“确实没有标题”；缺失或其它类型必须回源，不能伪造命中。
				if (value.title !== null && typeof value.title !== "string") continue;
				const title = value.title === "" ? null : value.title;
				entries.set(id, { title, revision: value.revision, at: typeof value.at === "number" ? value.at : 0 });
			}
			prune();
		} catch {
			entries.clear();
		}
	};

	/**
	 * 取缓存标题。
	 * @returns `{ hit: true, title }` 表示 **revision 相同、可零日志读取地复用**；
	 *          `{ hit: false }` 表示需要回源折叠。
	 */
	const get = (id, revision) => {
		if (typeof id !== "string" || id === "" || typeof revision !== "string" || revision === "") {
			return { hit: false };
		}
		const entry = entries.get(id);
		if (!entry || entry.revision !== revision) return { hit: false };
		// 命中也要刷新时间戳：淘汰按"最久未更新"，命中说明这个会话仍活跃。
		entry.at = now();
		dirty = true;
		return { hit: true, title: entry.title };
	};

	/** 写入（title 允许为 null——"确实没有标题"同样是可缓存的事实）。 */
	const set = (id, revision, title) => {
		if (typeof id !== "string" || id === "" || typeof revision !== "string" || revision === "") return;
		entries.set(id, {
			title: typeof title === "string" && title !== "" ? title : null,
			revision,
			at: now(),
		});
		dirty = true;
		prune();
	};

	/** 按 `at` 淘汰到上限以内。 */
	const prune = () => {
		if (entries.size <= maxEntries) return;
		const sorted = [...entries.entries()].sort((a, b) => a[1].at - b[1].at);
		const excess = entries.size - maxEntries;
		for (let i = 0; i < excess; i += 1) {
			entries.delete(sorted[i][0]);
			dirty = true;
		}
	};

	/** 原子落盘（临时文件 + rename）。没有变更时是空操作。 */
	const flush = () => {
		if (!dirty) return false;
		try {
			mkdirSync(dirname(file), { recursive: true });
			const tmp = `${file}.tmp`;
			writeFileSync(tmp, JSON.stringify({ version: 1, entries: Object.fromEntries(entries) }), "utf8");
			renameSync(tmp, file);
			dirty = false;
			return true;
		} catch {
			// 落盘失败不该影响本次响应：内存缓存仍然有效。
			return false;
		}
	};

	return {
		load,
		get,
		set,
		flush,
		size: () => entries.size,
		/** 仅测试用：直接观察某条目。 */
		peek: (id) => entries.get(id),
	};
};
