// 维护者对抗性复核（PR #18 用量与额度）：补 tools/account-usage-check.mjs 未覆盖的边界。
// 只调 lib/account-usage.js 的纯函数，无网络、不读凭据。
// 关注点：脏值不得变成错误的“健康”数字、耗尽的额度不得被丢掉、占位重置时间不得展示。
import assert from "node:assert/strict";

import {
  normalizeCodexUsage,
  normalizeDeepSeekBalance,
  normalizeOpenCodeUsage,
  usageWindowLabel,
} from "../lib/account-usage.js";

let passed = 0;
const cases = [];
const check = (name, fn) => cases.push([name, fn]);

// ── usageWindowLabel ────────────────────────────────────────────────
check("未知窗口秒数保持可读且稳定（90s / 24h / 2w）", () => {
  assert.equal(usageWindowLabel(90), "90s");
  assert.equal(usageWindowLabel(86_400), "24h");
  assert.equal(usageWindowLabel(1_209_600), "2w");
});

check("非法窗口秒数 → null（不产生 NaN 标签）", () => {
  for (const bad of [0, -1, "abc", null, undefined, NaN, Infinity]) {
    assert.equal(usageWindowLabel(bad), null);
  }
});

// ── normalizeDeepSeekBalance ────────────────────────────────────────
check("balance_infos 里混入非对象项时不崩，且仍优先 CNY", () => {
  const r = normalizeDeepSeekBalance({
    balance_infos: [null, "x", { currency: "USD", total_balance: "9.99" }, { currency: "CNY", total_balance: "1.23" }],
  });
  assert.equal(r.currency, "CNY");
  assert.equal(r.amount, "1.23");
});

check("余额字段是脏值 → 抛出（不得当成 0 元展示）", () => {
  assert.throws(() => normalizeDeepSeekBalance({ balance_infos: [{ currency: "CNY", total_balance: "abc" }] }));
  assert.throws(() => normalizeDeepSeekBalance({ balance_infos: [] }));
  assert.throws(() => normalizeDeepSeekBalance(null));
});

check("is_available=false 一路透传为 available=false", () => {
  assert.equal(normalizeDeepSeekBalance({ is_available: false, balance_infos: [{ currency: "CNY", total_balance: "0" }] }).available, false);
  assert.equal(normalizeDeepSeekBalance({ balance_infos: [{ currency: "CNY", total_balance: "0", is_available: false }] }).available, false);
});

// ── normalizeCodexUsage ─────────────────────────────────────────────
check("剩余 0% 的窗口必须保留（耗尽 ≠ 无数据）", () => {
  const r = normalizeCodexUsage({ rateLimits: [{ id: "codex", windows: [{ windowSeconds: 18_000, remainingPercent: 0 }] }] });
  assert.equal(r.windows.length, 1);
  assert.equal(r.windows[0].remainingPercent, 0);
});

check("剩余 >100% 或负数的窗口被丢弃（不产生越界进度条）", () => {
  const r = normalizeCodexUsage({
    rateLimits: [{ id: "codex", windows: [
      { windowSeconds: 18_000, remainingPercent: 101 },
      { windowSeconds: 604_800, remainingPercent: -5 },
      { windowSeconds: 2_592_000, remainingPercent: 42 },
    ] }],
  });
  assert.deepEqual(r.windows.map((w) => w.window), ["monthly"]);
});

check("同一 bucket 内重复窗口去重，且 resetAt=0 不产生 1970 年时间", () => {
  const r = normalizeCodexUsage({
    rateLimits: [{ id: "codex", windows: [
      { windowSeconds: 18_000, remainingPercent: 80, resetAt: 0 },
      { windowSeconds: 18_000, remainingPercent: 70 },
    ] }],
  });
  assert.equal(r.windows.length, 1);
  assert.equal(r.windows[0].remainingPercent, 80);
  assert.equal(r.windows[0].resetAt, undefined);
});

check("附加 bucket 的窗口带 bucket 名前缀，主 bucket 不带", () => {
  const r = normalizeCodexUsage({
    rateLimits: [
      { id: "codex", windows: [{ windowSeconds: 18_000, remainingPercent: 50 }] },
      { id: "other", name: "Codex Mini", windows: [{ windowSeconds: 604_800, remainingPercent: 10 }] },
    ],
  });
  assert.deepEqual(r.windows.map((w) => w.window), ["5h", "Codex Mini · weekly"]);
});

check("bucket 名过长被截断到 80 字符（防超长标签撑爆 UI）", () => {
  const r = normalizeCodexUsage({
    rateLimits: [{ id: "other", name: "X".repeat(200), windows: [{ windowSeconds: 18_000, remainingPercent: 50 }] }],
  });
  const label = r.windows[0].window;
  assert.ok(label.length <= 80 + 3 + 2, `label 过长: ${label.length}`);
});

check("rateLimits 类型错误 → 抛出；完全无可用额度 → 抛出", () => {
  assert.throws(() => normalizeCodexUsage({ rateLimits: "nope" }));
  assert.throws(() => normalizeCodexUsage({ rateLimits: [{ id: "codex", windows: [] }] }));
  assert.throws(() => normalizeCodexUsage(null));
});

check("individualLimit：limit=0 不做除法（不产生 Infinity 百分比）", () => {
  const r = normalizeCodexUsage({
    rateLimits: [{ id: "codex", windows: [{ windowSeconds: 18_000, remainingPercent: 50 }] }],
    individualLimit: { limit: 0, used: 0, remaining: 0 },
  });
  assert.equal(r.individualLimit, undefined);
});

check("individualLimit：缺 remainingPercent 时按 remaining/limit 推导", () => {
  const r = normalizeCodexUsage({
    rateLimits: [{ id: "codex", windows: [{ windowSeconds: 18_000, remainingPercent: 50 }] }],
    individualLimit: { limit: "200", used: "50", remaining: "150" },
  });
  assert.equal(r.individualLimit.remainingPercent, 75);
});

check("credits.unlimited=false 且 balance 缺失 → 仍是有效状态（可展示）", () => {
  const r = normalizeCodexUsage({
    rateLimits: [{ id: "codex", windows: [{ windowSeconds: 18_000, remainingPercent: 50 }] }],
    credits: { unlimited: false },
  });
  assert.deepEqual(r.credits, { unlimited: false });
});

// ── normalizeOpenCodeUsage ──────────────────────────────────────────
check("percent=100（用尽）→ remaining 0 且保留窗口", () => {
  const r = normalizeOpenCodeUsage({ usage: { rolling: { percent: 100, status: "ok" } } });
  assert.equal(r.windows[0].remainingPercent, 0);
});

check("percent 越界/缺失/状态未知 → 该窗口跳过", () => {
  assert.throws(() => normalizeOpenCodeUsage({ usage: { rolling: { percent: 101 } } }));
  assert.throws(() => normalizeOpenCodeUsage({ usage: { rolling: { percent: "abc" } } }));
  assert.throws(() => normalizeOpenCodeUsage({ usage: { rolling: { percent: 50, status: "paused" } } }));
});

check("percent=0 丢弃占位 resetAt，percent>0 保留", () => {
  const zero = normalizeOpenCodeUsage({ usage: { rolling: { percent: 0, resetsAt: "2026-09-22T00:00:00Z" } } });
  assert.equal(zero.windows[0].resetAt, undefined);
  const some = normalizeOpenCodeUsage({ usage: { rolling: { percent: 25, resetsAt: "2026-09-22T00:00:00Z" } } });
  assert.equal(some.windows[0].resetAt, "2026-09-22T00:00:00.000Z");
});

check("非法 resetsAt 字符串 → 不输出 resetAt（不产生 Invalid Date）", () => {
  const r = normalizeOpenCodeUsage({ usage: { weekly: { percent: 30, resetsAt: "not-a-date" } } });
  assert.equal(r.windows[0].resetAt, undefined);
});

check("rate-limited 标记透传，且三窗口顺序固定 5h/weekly/monthly", () => {
  const r = normalizeOpenCodeUsage({
    usage: {
      monthly: { percent: 10 },
      rolling: { percent: 20, status: "rate-limited" },
      weekly: { percent: 30 },
    },
  });
  assert.deepEqual(r.windows.map((w) => w.window), ["5h", "weekly", "monthly"]);
  assert.equal(r.windows[0].limited, true);
  assert.equal(r.windows[1].limited, undefined);
});

for (const [name, fn] of cases) {
  try {
    fn();
    passed++;
    console.log(`PASS  ${name}`);
  } catch (err) {
    console.log(`FAIL  ${name}\n      ${err.message.split("\n")[0]}`);
  }
}
console.log(`\n结果：${passed} 通过 / ${cases.length - passed} 失败`);
process.exit(passed === cases.length ? 0 : 1);
