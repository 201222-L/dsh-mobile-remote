// v3.1.4 真机验收（issue #14 P0）——对着**运行中**的插件跑，验证修复在真实宿主 + 真机链路下生效。
//
// 用法：
//   $env:DSH_MOBILE_TOKEN="<cordis.patch.yml 里的 authToken>"; node tools/verify-issue14-live.mjs
//   （可选 DSH_MOBILE_BASE，默认 http://127.0.0.1:3080/m）
//
// 覆盖：
//   1) 诊断字段就位：checks.pendingFrames / pendingApprovals / pendingQuestions + checks["push:<名>"]
//   2) 推送通道实测：POST /api/push-test → 逐通道结果（随后到 ntfy 通知栏确认**标题**是否正常）
//   3) 待答帧观察窗：默认 60s 内打印收到的 approval/requested、question/requested 帧
//      —— 期间请：杀掉手机 App → 在电脑端触发一次需要审批的操作
//      —— 期望：① 帧被记下（脚本会轮询 pendingFrames/pendingApprovals > 0）
//               ② 手机上（重新打开 App 后）出现审批卡并可作答
const T = process.env.DSH_MOBILE_TOKEN;
const base = process.env.DSH_MOBILE_BASE ?? "http://127.0.0.1:3080/m";
const watchSeconds = Number(process.env.DSH_WATCH_SECONDS ?? 60);
if (!T) {
	console.error("缺少 DSH_MOBILE_TOKEN 环境变量（取自 profile 的 cordis.patch.yml authToken）");
	process.exit(2);
}
const H = { "x-mobile-token": T, "content-type": "application/json" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const diag = async () => {
	const r = await fetch(`${base}/api/diagnostics`, { headers: H });
	return r.json();
};
const showChecks = (d, title) => {
	const c = d?.checks ?? {};
	console.log(`\n[${title}] 运行形态 ${d?.runtime?.form} · 手机在线 ${d?.runtime?.metrics?.mobileOnline} · 插件 v${d?.plugin?.version}`);
	console.log(`  待答：pendingApprovals=${c.pendingApprovals} pendingQuestions=${c.pendingQuestions} pendingFrames=${c.pendingFrames}`);
	console.log(`  审批策略：approvalMode=${c.approvalMode} remoteEvents=${c.remoteEvents}`);
	for (const [k, v] of Object.entries(c)) if (k.startsWith("push:")) console.log(`  推送通道 ${k.slice(5)} → ${v}`);
};

let pass = 0;
let fail = 0;
const check = (name, cond, extra = "") => {
	if (cond) { pass++; console.log(`PASS  ${name}`); } else { fail++; console.log(`FAIL  ${name}${extra ? `  ← ${extra}` : ""}`); }
};

// ── 1) 诊断字段就位 ────────────────────────────────────────────────────────
const d0 = await diag();
showChecks(d0, "起始状态");
check("新版本已加载（plugin ≥ 3.1.4）", String(d0?.plugin?.version ?? "") >= "3.1.4", `实际 ${d0?.plugin?.version}`);
check("checks.pendingApprovals 已输出（现代内核也可见）", typeof d0?.checks?.pendingApprovals === "number");
check("checks.pendingFrames 已输出", typeof d0?.checks?.pendingFrames === "number");
check(
	"每个推送通道都有最近投递结果",
	Object.keys(d0?.checks ?? {}).some((k) => k.startsWith("push:")),
	`实际 keys=${Object.keys(d0?.checks ?? {}).join(",")}`
);

// ── 2) 推送通道实测（ntfy 标题是本次修复的核心）─────────────────────────────
console.log("\n=== 推送通道自检（POST /api/push-test）===");
const pt = await (await fetch(`${base}/api/push-test`, { method: "POST", headers: H })).json();
for (const r of pt?.results ?? []) console.log(`  ${r.ok ? "✅" : "❌"} ${r.name}（${r.format}）${r.ok ? "" : ` → ${r.error}`}`);
check("至少一个通道投递成功", (pt?.results ?? []).some((r) => r.ok), JSON.stringify(pt?.results));
console.log("  ⚠ 请到手机通知栏确认：通知**有标题**（如「🔔 测试通知 · 配置验证」），而不是一坨 JSON。");
await sleep(500);
showChecks(await diag(), "推送后");

// ── 3) 待答帧观察窗 ───────────────────────────────────────────────────────
console.log(`\n=== 待答帧观察窗（${watchSeconds}s）===\n` + "请现在：杀掉手机 App（或开飞行模式断开）→ 在电脑端触发一次需要审批的操作。");
const ac = new AbortController();
setTimeout(() => ac.abort(), watchSeconds * 1000);
const seen = [];
try {
	const res = await fetch(`${base}/api/events`, { headers: { "x-mobile-token": T }, signal: ac.signal });
	const reader = res.body.getReader();
	const dec = new TextDecoder();
	let buf = "";
	for (;;) {
		const { value, done } = await reader.read();
		if (done) break;
		buf += dec.decode(value, { stream: true });
		const lines = buf.split("\n");
		buf = lines.pop() ?? "";
		for (const line of lines) {
			if (!line.startsWith("data: ")) continue;
			let msg = null;
			try { msg = JSON.parse(line.slice(6)); } catch { continue; }
			const frame = msg?.frame;
			if (frame?.type === "approval/requested" || frame?.type === "question/requested") {
				seen.push(frame);
				console.log(`  收到待答帧：${frame.type} approvalId/questionId=${frame.approvalId ?? frame.questionId} 会话=${frame.sessionId}`);
				const d = await diag();
				console.log(`    → 诊断：pendingApprovals=${d?.checks?.pendingApprovals} pendingQuestions=${d?.checks?.pendingQuestions} pendingFrames=${d?.checks?.pendingFrames}`);
			}
		}
	}
} catch { /* abort：观察窗结束 */ }

check("观察窗内收到待答帧（离线期间记账 → 重连回放）", seen.length > 0, "未收到帧：确认期间确实触发了审批/问询，且 App 曾断开重连");
const dEnd = await diag();
check("结束时无残留幽灵卡（pendingFrames 归零）", dEnd?.checks?.pendingFrames === 0, `实际 ${dEnd?.checks?.pendingFrames}（若 >0 说明条目未被 · 清理，需要贴出上面的帧与诊断）`);

console.log(`\n结果：PASS ${pass} / FAIL ${fail}`);
process.exit(fail === 0 ? 0 : 1);
