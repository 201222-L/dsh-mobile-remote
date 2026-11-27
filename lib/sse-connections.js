/**
 * issue #131：SSE 连接准入策略（纯函数，无 HTTP/无副作用，便于单测）。
 *
 * 真机症状：只有一台手机，`mobileOnline = 16 / 16`，新 `/m/api/events` 永久 503，
 * 只能重启宿主。App 侧泄漏已修（9670849），宿主侧仍需兜底：
 * - 满额时**不直接 503**，先驱逐「满龄且优先 stalled」的候选连接，再接受新连接；
 * - 候选必须 `age >= minAgeMs`（默认 60s）：只能保证"60s 内不驱逐"，不保证不误踢；
 * - 每次准入最多驱逐 1 条，绝不通过调大 maxConnections 掩盖泄漏。
 *
 * 排序（架构顾问 #131 契约 + Reviewer 预审 P3 收口）：
 *   **stalled 优先** > 同 clientId（若双方都有）> 同 clientIp > 全局最旧。
 *
 * 重要语义边界：`age >= 60s` 只是**可驱逐门槛**，不是"活跃/陈旧"判据——真实活跃设备
 * 也可能连接超过 60s；`stalled` 也只是排序/日志信号（半开连接的 `res.write` 可能仍成功，
 * 不能用"写成功"证明还活着）。两者合起来仍是启发式，不能宣称"不会误踢活跃连接"。
 */

/** 满龄候选的最小年龄（毫秒）：低于此年龄的连接一律不驱逐（硬门槛，不等于判活）。 */
export const SSE_EVICT_MIN_AGE_MS = 60_000;
/** 服务端 SSE 心跳间隔（毫秒）：与既有 `: ping` 周期一致。 */
export const SSE_HEARTBEAT_MS = 25_000;
/** 无成功写的 stalled 判定（毫秒）：约 2 个心跳周期。 */
export const SSE_STALL_IDLE_MS = 50_000;
/** SSE 背压阈值（字节）：与 v2.7.2 review(M5) 一致。 */
export const SSE_BACKPRESSURE_BYTES = 256 * 1024;
/** 503 拒绝日志汇总窗口（毫秒）：避免 App 重试风暴刷屏。 */
export const SSE_REJECT_LOG_WINDOW_MS = 30_000;

/**
 * 创建一条 SSE 连接的元数据。
 *
 * `id` 仅用于日志/诊断关联，不含 token/cookie；`clientIp` / `appVersion` / `clientId`
 * 都来自请求头或 socket，只用于准入排序与排障，不参与鉴权。
 */
export function createSseConnectionMeta({ id, now = Date.now(), clientIp = "", appVersion = "", clientId = "" }) {
	return {
		id,
		createdAt: now,
		lastWriteAt: now,
		lastHeartbeatAt: now,
		writeFailures: 0,
		backpressure: false,
		clientIp,
		appVersion,
		clientId,
	};
}

/** 是否处于 stalled 状态（只用于排序/日志，不作为驱逐的唯一判据）。 */
export function isSseConnectionStalled(meta, now = Date.now()) {
	if (!meta) return false;
	if (meta.writeFailures > 0) return true;
	if (meta.backpressure === true) return true;
	return now - meta.lastWriteAt >= SSE_STALL_IDLE_MS;
}

/**
 * 连接统计（诊断指标）：最旧年龄 / 最久无成功写 / stalled 数 / 满龄候选数（非陈旧数）。
 *
 * @param {{res: unknown, meta: object}[]} entries
 */
export function sseConnectionStats(entries, now = Date.now(), { minAgeMs = SSE_EVICT_MIN_AGE_MS } = {}) {
	let total = 0;
	let oldestAgeMs = 0;
	let oldestIdleMs = 0;
	let stalled = 0;
	// 仅表示"年龄达到可驱逐门槛"的候选数，不等于陈旧/活跃判定（Reviewer P3）。
	let ageEligible = 0;
	for (const entry of entries ?? []) {
		const meta = entry?.meta;
		if (!meta) continue;
		total += 1;
		const ageMs = Math.max(0, now - meta.createdAt);
		const idleMs = Math.max(0, now - meta.lastWriteAt);
		if (ageMs > oldestAgeMs) oldestAgeMs = ageMs;
		if (idleMs > oldestIdleMs) oldestIdleMs = idleMs;
		if (isSseConnectionStalled(meta, now)) stalled += 1;
		if (ageMs >= minAgeMs) ageEligible += 1;
	}
	return { total, oldestAgeMs, oldestIdleMs, stalled, ageEligible };
}

/** 毫秒 → 紧凑可读（日志/诊断用）。 */
export function formatDurationMs(ms) {
	if (!Number.isFinite(ms) || ms <= 0) return "0s";
	if (ms < 1000) return `${Math.round(ms)}ms`;
	if (ms < 60_000) return `${Math.round(ms / 1000)}s`;
	if (ms < 3_600_000) return `${Math.floor(ms / 60_000)}m${Math.round((ms % 60_000) / 1000)}s`;
	return `${Math.floor(ms / 3_600_000)}h${Math.floor((ms % 3_600_000) / 60_000)}m`;
}

function identityTier(meta, incoming) {
	const wantedClientId = typeof incoming?.clientId === "string" ? incoming.clientId : "";
	if (wantedClientId !== "" && typeof meta.clientId === "string" && meta.clientId === wantedClientId) return 0;
	const wantedIp = typeof incoming?.clientIp === "string" ? incoming.clientIp : "";
	if (wantedIp !== "" && typeof meta.clientIp === "string" && meta.clientIp === wantedIp) return 1;
	return 2;
}

const TIER_REASON = ["same-client-id", "same-client-ip", "oldest"];

/**
 * 准入决策（纯函数）：未满直接 accept；满池才调用 planConnectionAdmission；
 * 候选不存在则 reject；任何情况下最多返回 1 条 evict。
 *
 * @returns {{action: "accept"} |
 *   {action: "evict", evict: object} |
 *   {action: "reject", reason: string}}
 */
export function decideConnectionAdmission({ currentSize, maxConnections, entries, incoming = {}, now = Date.now(), minAgeMs = SSE_EVICT_MIN_AGE_MS }) {
	if (currentSize < maxConnections) return { action: "accept" };
	// 配额被调小到低于当前连接数：不通过连续驱逐掩盖配置问题（每次准入最多 1 条的原则）。
	if (currentSize > maxConnections) return { action: "reject", reason: "over-capacity" };
	const plan = planConnectionAdmission({ entries, incoming, now, minAgeMs });
	if (!plan.evict) return { action: "reject", reason: "no-eligible" };
	return { action: "evict", evict: plan.evict };
}

/**
 * 满池时的准入计划：最多返回 1 条可驱逐连接；没有年龄达标的候选就拒绝。
 *
 * **只在 `connections.size >= maxConnections` 时调用**；未满池直接接受，不经过本函数。
 *
 * @param {object} args
 * @param {{res: unknown, meta: object}[]} args.entries 当前在网连接
 * @param {{clientIp?: string, clientId?: string}} [args.incoming] 新连接的来源信息
 * @param {number} [args.now]
 * @param {number} [args.minAgeMs] 安全年龄（默认 60s）
 * @returns {{evict: null | {res: unknown, meta: object, ageMs: number, idleMs: number, stalled: boolean, reason: string, eligible: number}, eligible: number, stalled: number}}
 */
export function planConnectionAdmission({ entries, incoming = {}, now = Date.now(), minAgeMs = SSE_EVICT_MIN_AGE_MS }) {
	const eligible = [];
	for (const entry of entries ?? []) {
		const meta = entry?.meta;
		if (!meta) continue;
		const ageMs = Math.max(0, now - meta.createdAt);
		if (ageMs < minAgeMs) continue;
		eligible.push({
			res: entry.res,
			meta,
			ageMs,
			idleMs: Math.max(0, now - meta.lastWriteAt),
			stalled: isSseConnectionStalled(meta, now),
			tier: identityTier(meta, incoming),
		});
	}
	if (eligible.length === 0) {
		return { evict: null, eligible: 0, stalled: 0 };
	}
	for (const candidate of eligible) candidate.reason = TIER_REASON[candidate.tier];
	eligible.sort(
		(a, b) =>
			(a.stalled === b.stalled ? 0 : a.stalled ? -1 : 1) ||
			a.tier - b.tier ||
			a.meta.createdAt - b.meta.createdAt ||
			String(a.meta.id ?? "").localeCompare(String(b.meta.id ?? "")),
	);
	const best = eligible[0];
	return {
		evict: {
			res: best.res,
			meta: best.meta,
			ageMs: best.ageMs,
			idleMs: best.idleMs,
			stalled: best.stalled,
			reason: best.reason,
			eligible: eligible.length,
		},
		eligible: eligible.length,
		stalled: eligible.filter((candidate) => candidate.stalled).length,
	};
}
