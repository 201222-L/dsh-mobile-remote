// issue #20 第 2 步：revision 失效的持久化标题缓存。
//
// 断言的是**行为**：给定 revision 是否命中、跨进程重启是否仍命中、损坏与超限如何降级。
// 不锁内部结构（除了 peek 用于观察淘汰）。
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import test from "node:test";

import { createTitleCache, DEFAULT_MAX_ENTRIES } from "../lib/session-title-cache.js";

const withDir = (fn) => {
	const dir = mkdtempSync(join(tmpdir(), "title-cache-"));
	try {
		return fn(dir);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
};

test("revision 相同 → 命中并复用标题；revision 变化 → 未命中（必须回源）", () => {
	withDir((dir) => {
		const cache = createTitleCache({ file: join(dir, "t.json") });
		cache.set("s1", "rev-a", "标题 A");
		assert.deepEqual(cache.get("s1", "rev-a"), { hit: true, title: "标题 A" },
			"revision 未变即意味着日志没变，可零日志读取地复用");
		assert.deepEqual(cache.get("s1", "rev-b"), { hit: false },
			"revision 变了必须回源，不得用旧标题");
		assert.deepEqual(cache.get("unknown", "rev-a"), { hit: false }, "没存过的不命中");
	});
});

test("落盘后由新的缓存实例读回 → 仍命中（跨宿主重启有效）", () => {
	withDir((dir) => {
		const file = join(dir, "t.json");
		const first = createTitleCache({ file });
		first.set("s1", "rev-a", "标题 A");
		first.set("s2", "rev-b", null); // 确实没有标题，也是可缓存的事实
		assert.equal(first.flush(), true, "有变更时应真的落盘");

		const second = createTitleCache({ file });
		second.load();
		assert.deepEqual(second.get("s1", "rev-a"), { hit: true, title: "标题 A" },
			"重启后 revision 未变仍应命中——这正是 note 702 方向 2 要的效果");
		assert.deepEqual(second.get("s2", "rev-b"), { hit: true, title: null },
			"null 标题同样是可缓存事实，避免每次重算");
	});
});

test("无变更时 flush 是空操作，不产生写盘", () => {
	withDir((dir) => {
		const cache = createTitleCache({ file: join(dir, "t.json") });
		assert.equal(cache.flush(), false, "没有任何变更不应落盘");
		cache.set("s1", "rev-a", "A");
		assert.equal(cache.flush(), true);
		assert.equal(cache.flush(), false, "刚落过盘、又无新变更 → 仍应是空操作");
	});
});

test("缓存文件损坏或缺失 → 当作空缓存，不抛异常", () => {
	withDir((dir) => {
		const missing = createTitleCache({ file: join(dir, "nope.json") });
		missing.load();
		assert.equal(missing.size(), 0, "文件不存在 → 空缓存");
		assert.deepEqual(missing.get("s1", "rev"), { hit: false });

		const file = join(dir, "bad.json");
		writeFileSync(file, "{ 这不是 JSON", "utf8");
		const broken = createTitleCache({ file });
		broken.load();
		assert.equal(broken.size(), 0, "损坏文件 → 空缓存（缓存坏了不该让列表挂掉）");
	});
});

test("合法 JSON 中缺失或非法 title 应未命中，而非伪命中 null", () => {
	withDir((dir) => {
		const invalidRows = [
			{ revision: "r1", at: 1 },
			{ revision: "r1", title: 42, at: 1 },
			{ revision: "r1", title: { text: "invalid" }, at: 1 },
		];
		invalidRows.forEach((row, i) => {
			const file = join(dir, `invalid-${i}.json`);
			writeFileSync(file, JSON.stringify({ version: 1, entries: { s1: row } }));
			const cache = createTitleCache({ file });
			cache.load();
			assert.deepEqual(cache.get("s1", "r1"), { hit: false }, `row ${i} 必须回源`);
		});
	});
});

test("显式 null 与空字符串仍按无标题事实缓存", () => {
	withDir((dir) => {
		const file = join(dir, "null-title.json");
		writeFileSync(file, JSON.stringify({
			version: 1,
			entries: {
				explicitNull: { revision: "r1", title: null, at: 1 },
				emptyString: { revision: "r2", title: "", at: 2 },
			},
		}));
		const cache = createTitleCache({ file });
		cache.load();
		assert.deepEqual(cache.get("explicitNull", "r1"), { hit: true, title: null });
		assert.deepEqual(cache.get("emptyString", "r2"), { hit: true, title: null });
	});
});

test("load 只接受 version 1，并以文件内容替换内存快照", () => {
	withDir((dir) => {
		const file = join(dir, "version.json");
		const cache = createTitleCache({ file });
		cache.set("stale", "r0", "旧条目");
		writeFileSync(file, JSON.stringify({
			version: 2,
			entries: { future: { revision: "r1", title: "未来格式" } },
		}));
		cache.load();
		assert.equal(cache.size(), 0, "未知版本必须降级为空缓存，而不是误读未来格式");
		assert.deepEqual(cache.get("stale", "r0"), { hit: false }, "load 应替换而非合并旧内存条目");

		writeFileSync(file, JSON.stringify({
			version: 1,
			entries: { current: { revision: "r2", title: "当前标题", at: 3 } },
		}));
		cache.load();
		assert.deepEqual(cache.get("current", "r2"), { hit: true, title: "当前标题" });
		assert.deepEqual(cache.get("future", "r1"), { hit: false });
	});
});

test("非法输入被忽略：空 id/revision 不写入也不命中", () => {
	withDir((dir) => {
		const cache = createTitleCache({ file: join(dir, "t.json") });
		cache.set("", "rev", "x");
		cache.set("s1", "", "x");
		assert.equal(cache.size(), 0, "空 id 或空 revision 不得写入");
		assert.deepEqual(cache.get("s1", ""), { hit: false });
	});
});

test("条目数有界：超出上限按最久未更新淘汰", () => {
	withDir((dir) => {
		let clock = 1000;
		const cache = createTitleCache({ file: join(dir, "t.json"), maxEntries: 3, now: () => (clock += 10) });
		cache.set("a", "r", "A");
		cache.set("b", "r", "B");
		cache.set("c", "r", "C");
		assert.equal(cache.size(), 3);
		cache.set("d", "r", "D"); // 触发淘汰：最久未更新的 a 出局
		assert.equal(cache.size(), 3, "必须有界——note 793 明确要求");
		assert.equal(cache.peek("a"), undefined, "应淘汰最久未更新者");
		assert.notEqual(cache.peek("d"), undefined);
	});
});

test("命中会刷新时间戳：活跃会话不会被先淘汰", () => {
	withDir((dir) => {
		let clock = 1000;
		const cache = createTitleCache({ file: join(dir, "t.json"), maxEntries: 2, now: () => (clock += 10) });
		cache.set("a", "r", "A");
		cache.set("b", "r", "B");
		cache.get("a", "r"); // a 被使用 → 比 b 新
		cache.set("c", "r", "C"); // 淘汰 b
		assert.notEqual(cache.peek("a"), undefined, "刚命中的 a 不应被淘汰");
		assert.equal(cache.peek("b"), undefined);
	});
});

test("默认上限是 1000（与注释一致，避免文档漂移）", () => {
	assert.equal(DEFAULT_MAX_ENTRIES, 1000);
});
