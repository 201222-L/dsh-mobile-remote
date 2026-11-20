// issue #131：SSE 准入策略的纯函数单测（不启 HTTP、不写磁盘）。
//
// 契约（架构顾问）：保留到底层 `connections: Set` 与 `mobileOnline` 语义，满池时
// 只按策略驱逐「最旧且超过安全年龄」的连接；候选必须 age >= 60s；优先同 clientId
// （若有）→ 同 clientIp → 全局最旧；每次准入最多 1 条；绝不调大 maxConnections。
import test from "node:test";
import assert from "node:assert/strict";
import {
	createSseConnectionMeta,
	decideConnectionAdmission,
	isSseConnectionStalled,
	planConnectionAdmission,
	SSE_EVICT_MIN_AGE_MS,
	SSE_STALL_IDLE_MS,
	sseConnectionStats,
} from "../lib/sse-connections.js";

const NOW = 1_000_000;
const MIN_AGE = SSE_EVICT_MIN_AGE_MS;

/**
 * 造一条连接。`ageMs` 决定建立时间；`stalled` 用"最后成功写早于 50s"表达，
 * 也可以显式传 `writeFailures` / `backpressure` 覆盖。
 */
function entry(id, { ageMs = 0, clientIp = "", clientId = "", writeFailures = 0, backpressure = false } = {}) {
	const meta = createSseConnectionMeta({ id, now: NOW - ageMs, clientIp, clientId });
	if (writeFailures > 0) meta.writeFailures = writeFailures;
	if (backpressure) meta.backpressure = true;
	if (ageMs > SSE_STALL_IDLE_MS && writeFailures === 0 && !backpressure) {
		// 只要不是显式指定其他 stalled 原因，老连接默认"最后写"也停在建立时刻。
		meta.lastWriteAt = meta.createdAt;
	}
	return { res: { id }, meta };
}

function decide({ currentSize, maxConnections = 16, entries, incoming = {}, now = NOW }) {
	return decideConnectionAdmission({ currentSize, maxConnections, entries, incoming, now, minAgeMs: MIN_AGE });
}

test("stalled 判定：写失败 / 背压 / 50s 无成功写；活跃连接不算 stalled", () => {
	assert.equal(isSseConnectionStalled(createSseConnectionMeta({ id: "c1", now: NOW }), NOW), false);
	assert.equal(isSseConnectionStalled(entry("c2", { ageMs: 10_000, writeFailures: 1 }).meta, NOW), true);
	assert.equal(isSseConnectionStalled(entry("c3", { ageMs: 10_000, backpressure: true }).meta, NOW), true);
	assert.equal(isSseConnectionStalled(entry("c4", { ageMs: SSE_STALL_IDLE_MS }).meta, NOW), true);
	const freshWrite = entry("c5", { ageMs: 10 * 60_000 }).meta;
	freshWrite.lastWriteAt = NOW - 1_000; // 心跳刚更新过
	assert.equal(isSseConnectionStalled(freshWrite, NOW), false);
});

test("未满池：直接 accept，不进入驱逐策略", () => {
	const decision = decide({
		currentSize: 2,
		maxConnections: 3,
		entries: [entry("a"), entry("b")],
	});
	assert.deepEqual(decision, { action: "accept" });
});

test("满池但全部年轻：reject no-eligible，不踢活跃连接", () => {
	const entries = [
		entry("a", { ageMs: MIN_AGE - 1 }),
		entry("b", { ageMs: 1_000 }),
		entry("c", { ageMs: 0 }),
	];
	const decision = decide({ currentSize: 3, maxConnections: 3, entries });
	assert.deepEqual(decision, { action: "reject", reason: "no-eligible" });
	const plan = planConnectionAdmission({ entries, incoming: {}, now: NOW, minAgeMs: MIN_AGE });
	assert.equal(plan.evict, null);
	assert.equal(plan.eligible, 0);
});

test("满池且有 60s+ 候选：只驱逐最旧 1 条（不是最新、不是多条）", () => {
	const entries = [
		entry("young", { ageMs: 30_000 }),
		entry("middle", { ageMs: 120_000 }),
		entry("oldest", { ageMs: 300_000 }),
	];
	const decision = decide({ currentSize: 3, maxConnections: 3, entries });
	assert.equal(decision.action, "evict");
	assert.equal(decision.evict.meta.id, "oldest");
	assert.equal(decision.evict.ageMs, 300_000);
	assert.equal(decision.evict.reason, "oldest");
	assert.equal(decision.evict.eligible, 2, "只有两条达到安全年龄");
	// 恰好 60s 也算达标。
	const boundary = decide({
		currentSize: 1,
		maxConnections: 1,
		entries: [entry("boundary", { ageMs: MIN_AGE })],
	});
	assert.equal(boundary.action, "evict");
	assert.equal(boundary.evict.meta.id, "boundary");
});

test("同 clientIp 优先：同源连接即使不是全局最旧也先被驱逐", () => {
	const entries = [
		entry("same-ip", { ageMs: 70_000, clientIp: "10.0.0.7" }),
		entry("other-ip-oldest", { ageMs: 400_000, clientIp: "10.0.0.8" }),
	];
	const decision = decide({ currentSize: 2, maxConnections: 2, entries, incoming: { clientIp: "10.0.0.7" } });
	assert.equal(decision.evict.meta.id, "same-ip");
	assert.equal(decision.evict.reason, "same-client-ip");
});

test("同 clientId 优先于同 IP：跨网络重连也能优先清掉自己的旧连接", () => {
	const entries = [
		entry("same-id", { ageMs: 65_000, clientIp: "10.0.0.3", clientId: "device-1" }),
		entry("same-ip", { ageMs: 70_000, clientIp: "10.0.0.7", clientId: "device-2" }),
		entry("other", { ageMs: 500_000, clientIp: "10.0.0.9", clientId: "device-3" }),
	];
	const decision = decide({
		currentSize: 3,
		maxConnections: 3,
		entries,
		incoming: { clientId: "device-1", clientIp: "10.0.0.7" },
	});
	assert.equal(decision.evict.meta.id, "same-id");
	assert.equal(decision.evict.reason, "same-client-id");
});

test("每次准入最多驱逐 1 条：即使多条都达标也只返回一个候选", () => {
	const entries = ["a", "b", "c", "d"].map((id) => entry(id, { ageMs: 10 * 60_000 }));
	const decision = decide({ currentSize: 4, maxConnections: 4, entries });
	assert.equal(decision.action, "evict");
	assert.ok(decision.evict && !Array.isArray(decision.evict));
	assert.equal(decision.evict.meta.id, "a", "建立时间相同按 id 稳定排序");
});

test("stalled 优先于同 clientIp 健康连接（Reviewer P3：先踢半开，再谈同源）", () => {
	const sameIpHealthy = entry("same-ip-healthy", { ageMs: 120_000, clientIp: "10.0.0.7" });
	sameIpHealthy.meta.lastWriteAt = NOW - 1_000; // 心跳新鲜 → 健康
	const otherIpStalled = entry("other-ip-stalled", { ageMs: 61_000, clientIp: "10.0.0.8" });
	otherIpStalled.meta.writeFailures = 1;
	const decision = decide({
		currentSize: 2,
		maxConnections: 2,
		entries: [sameIpHealthy, otherIpStalled],
		incoming: { clientIp: "10.0.0.7" },
	});
	assert.equal(decision.evict.meta.id, "other-ip-stalled");
	assert.equal(decision.evict.stalled, true);
});

test("stalled 排序：同身份层级内优先驱逐 stalled（半开）连接", () => {
	const stalled = entry("stalled", { ageMs: 70_000 });
	stalled.meta.writeFailures = 1;
	const active = entry("active", { ageMs: 300_000 });
	active.meta.lastWriteAt = NOW - 1_000; // 心跳刚写过：年龄很大但并未 stalled
	const decision = decide({
		currentSize: 2,
		maxConnections: 2,
		entries: [active, stalled],
	});
	assert.equal(decision.evict.meta.id, "stalled");
	assert.equal(decision.evict.stalled, true);
});

test("配额被调小（当前数 > 上限）：reject over-capacity，不连续驱逐", () => {
	const entries = ["a", "b", "c", "d"].map((id) => entry(id, { ageMs: 10 * 60_000 }));
	const decision = decide({ currentSize: 4, maxConnections: 2, entries });
	assert.deepEqual(decision, { action: "reject", reason: "over-capacity" });
});

test("统计：最旧年龄 / 最久无写 / stalled / 满龄候选", () => {
	const entries = [
		entry("new", { ageMs: 5_000 }),
		entry("old", { ageMs: 10 * 60_000 }),
		entry("stalled", { ageMs: 70_000, writeFailures: 1 }),
	];
	const stats = sseConnectionStats(entries, NOW, { minAgeMs: MIN_AGE });
	assert.equal(stats.total, 3);
	assert.equal(stats.oldestAgeMs, 10 * 60_000);
	assert.equal(stats.oldestIdleMs, 10 * 60_000, "old 的最后写停在建立时刻");
	assert.equal(stats.stalled, 2, "old 超过 50s 无成功写，stalled 也算");
	assert.equal(stats.ageEligible, 2, "满龄候选只表示年龄门槛，不等于陈旧数");
});
