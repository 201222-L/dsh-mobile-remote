// 用量与额度服务端纯函数自检：不触发真实 provider 请求，不读取凭据。
import { normalizeCodexUsage, normalizeDeepSeekBalance, normalizeOpenCodeUsage, usageWindowLabel } from "../lib/account-usage.js";

let pass = 0;
let fail = 0;
const check = (name, condition, extra = "") => {
  if (condition) {
    pass++;
    console.log(`PASS  ${name}`);
  } else {
    fail++;
    console.log(`FAIL  ${name} ${extra}`);
  }
};

check("5 小时窗口标签", usageWindowLabel(18_000) === "5h");
check("周窗口标签", usageWindowLabel(604_800) === "weekly");
check("未知窗口标签稳定", usageWindowLabel(7_200) === "2h");
const deepSeek = normalizeDeepSeekBalance({
  is_available: true,
  balance_infos: [
    { currency: "USD", total_balance: "3.00" },
    { currency: "CNY", total_balance: "12.50" },
  ],
});
check("DeepSeek 读取顶层余额并优先 CNY", deepSeek.amount === "12.50" && deepSeek.currency === "CNY" && deepSeek.available === true);

const codex = normalizeCodexUsage({
  rateLimits: [
    { id: "other", windows: [{ windowSeconds: 18_000, remainingPercent: 1 }] },
    { id: "codex", windows: [
      { windowSeconds: 18_000, remainingPercent: 72, resetAt: 1_800_000_000 },
      { windowSeconds: 604_800, remainingPercent: 64 },
    ] },
  ],
  credits: { unlimited: false, balance: "8.00" },
  individualLimit: { limit: "100", used: "28", remaining: "72", remainingPercent: 72 },
});
check("Codex 精确优先 codex bucket 且保留 additional bucket", codex.windows.length === 3 && codex.windows[0].remainingPercent === 72 && codex.windows[2].window === "other · 5h");
check("Codex resetAt 脱敏为 ISO 时间", codex.windows[0].resetAt?.endsWith("Z") === true);
check("Codex Credits 保留金额", codex.credits?.balance === "8.00");
check("Codex 个人消费上限独立保留", codex.individualLimit?.remaining === "72");
const unlimited = normalizeCodexUsage({ credits: { unlimited: true } });
check("Codex 无限 Credits 不伪造金额", unlimited.credits?.unlimited === true && unlimited.credits.balance === undefined);
const noBalance = normalizeCodexUsage({ credits: { unlimited: false } });
check("Codex 无余额 Credits 仍保留状态", noBalance.credits?.unlimited === false && noBalance.credits.balance === undefined);

const go = normalizeOpenCodeUsage({ usage: {
  rolling: { status: "ok", percent: 12, resetsAt: "2030-01-01T00:00:00Z" },
  weekly: { status: "ok", percent: 40 },
  monthly: { status: "error", percent: 50 },
} });
check("OpenCode 已用百分比转换为剩余百分比", go.windows[0].remainingPercent === 88);
check("OpenCode 未知状态窗口单独跳过", go.windows.length === 2);
check("OpenCode 保留重置时间", typeof go.windows[0].resetAt === "string");
const limited = normalizeOpenCodeUsage({ usage: {
  weekly: { status: "rate-limited", percent: 100, resetsAt: "2030-01-02T00:00:00Z" },
} });
check("OpenCode rate-limited 窗口保留为 0%", limited.windows[0].remainingPercent === 0 && limited.windows[0].limited === true);
const fresh = normalizeOpenCodeUsage({ usage: {
  rolling: { status: "ok", percent: 0, resetsAt: "2030-01-03T00:00:00Z" },
} });
check("OpenCode percent=0 丢弃占位 resetAt", fresh.windows[0].resetAt === undefined);

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
