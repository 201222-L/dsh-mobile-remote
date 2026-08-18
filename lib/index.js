/**
 * dsh-mobile-remote — 手机远程操作 dsh agent 的 host 插件。
 *
 * 在 web profile 的 webserver 上注册 /m 前缀路由，提供一个零构建的
 * 移动网页（lib/page.html）：发消息（agent.followup）、看进度与收通知
 * （session/event + agent/status 事件桥 → SSE）、会话历史、二维码、充值入口。
 *
 * 设计依据见 docs/01-PRD.md ~ docs/04-security.md。
 */
import { networkInterfaces, homedir } from "node:os";
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join } from "node:path";
import z from "@deepseek-ai/schemastery";
import QRCode from "qrcode";
import { createUserMessage } from "@deepseek-ai/dsh-llm";
import { setSandboxMode } from "@deepseek-ai/dsh-sandbox-policy";
import { credentialRef } from "@deepseek-ai/dsh-credentials";

/** Cordis 插件名（cordis.patch.yml 中按此 id 引用）。 */
export const name = "mobile-remote";
/** 必需服务：webServer 是路由载体；agents/sessions 惰性获取。 */
export const inject = ["webServer"];

/** 插件配置 schema。 */
export const Config = z.object({
	/** 移动页挂载路径：单段、以 / 开头。禁止 "/"（会劫持桌面 SPA fallback）。 */
	path: z.string().pattern(/^\/[a-zA-Z0-9_-]+$/).default("/m"),
	/** 访问口令；空 = 关闭认证（信任网络层）。建议 ≥16 字符随机串。 */
	authToken: z.string().default(""),
	/** 认证 cookie 名。 */
	cookieName: z.string().default("dsh_mobile_token"),
	/**
	 * 额外可信主机（Host 校验白名单扩展）：内网穿透/中继场景显式声明。
	 * 例如 frp 中转时 App 通过 `http://<VPS地址>:3080` 访问，请求的 Host 头是 VPS 地址，
	 * 默认 Host 校验会拒绝；把 VPS 地址（IP 或域名，不带端口）加进此列表即可放行。
	 * 注意：仅在确信中继通道安全（加密隧道）+ 开启 authToken 的前提下配置。
	 */
	trustedHosts: z.array(z.string()).default([]),
	/** 登录会话有效期（毫秒），默认 30 天。 */
	sessionTtlMs: z.number().default(30 * 24 * 3600 * 1000),
	/** 充值入口跳转地址。 */
	rechargeUrl: z.string().default("https://platform.deepseek.com/top_up"),
	/** SSE 连接数上限。 */
	maxConnections: z.number().default(16),
	/**
	 * 推送桥（Phase 2）：agent 完成/需要回答/失败 → 手机系统通知。
	 * 每个条目一个通道；format:
	 *   serverchan — POST url（形如 https://sctapi.ftqq.com/<SendKey>.send），form: title/desp
	 *   ntfy        — POST url（形如 https://ntfy.sh/<topic>），text/plain + X-Title 头
	 *   bark        — POST url（形如 https://api.day.app/<key>），json: { title, body }
	 *   generic     — POST url，json: { kind, title, detail, sessionId, time }
	 */
	pushUrls: z
		.array(z.object({ name: z.string().default("push"), url: z.string().required(), format: z.string().default("generic") }))
		.default([]),
	/** 推送节流：同会话同类型的最小间隔（毫秒），默认 60 秒。 */
	pushCooldownMs: z.number().default(60_000),
	/**
	 * 推送内容级别（v2.6.0）：
	 *   minimal  — 默认。只推事件类型 + 会话短码，会话标题/错误详情等核心内容
	 *              不进第三方推送通道（Server酱/ntfy/Bark 等）。
	 *   standard — 含会话标题与事件详情（旧行为）。第三方服务会看到这些内容，
	 *              仅在信任通道时开启。
	 */
	pushContent: z.string().default("minimal"),
	/**
	 * 登录失败限流（v2.6.0，仅 authToken 启用时生效）：
	 * 窗口内失败次数 ≥ maxFailures → 429，窗口过后自动恢复；认证成功重置计数。
	 */
	rateLimit: z
		.object({
			maxFailures: z.number().default(10),
			windowMs: z.number().default(60_000),
			blockMs: z.number().default(60_000),
		})
		.default({}),
});

/**
 * 会话"表面"事件白名单：历史加载与增量补漏只返回这些类型。
 * 日志里 token 级 assistant/chunk、inbox 拼接、请求头等事件动辄十万级，
 * 全量下发会淹没移动端；assistant/message 完成事件兜底完整回复。
 * SSE 实时流仍广播全量（chunk 提供流式体验），history 才过滤。
 */
const SURFACE_TYPES = new Set(["user/message", "assistant/message", "tool/call", "tool/result", "turn/start", "turn/end"]);

/** 截断字符串到上限（超出加省略号），避免移动端流量/渲染膨胀。 */
function clampText(text, max) {
	if (text.length <= max) return text;
	return `${text.slice(0, max)}\n…（已截断）`;
}

/** 从 ContentBlock[] 提取纯文本（默认过滤 tool-call；user 消息的 image 保留占位）。 */
function blocksToText(blocks, { includeToolCalls = false } = {}) {
	let out = "";
	for (const block of blocks ?? []) {
		if (block?.type === "text") out += block.text;
		else if (block?.type === "tool-call" && includeToolCalls) out += `\n[工具调用: ${block.name}]\n`;
		else if (block?.type === "image") out += "\n[图片]\n";
	}
	return out;
}

/** 统计 reasoning 字符数。 */
function reasoningChars(blocks) {
	let n = 0;
	for (const block of blocks ?? []) if (block?.type === "reasoning") n += block.text.length;
	return n;
}

/**
 * 把 SessionEvent 裁剪成移动端摘要（docs/03-api.md §3.7）。
 * 返回 { seq, type, data? }；未识别类型仅保留 type，客户端忽略。
 */
export function summarizeEvent(event) {
	const { seq, type, data } = event;
	switch (type) {
		case "user/message": {
			const message = data;
			return { seq, type, data: { messageId: message.id, text: clampText(blocksToText(message.content), 2000) } };
		}
		case "assistant/message": {
			const message = data.message;
			return {
				seq,
				type,
				data: {
					turn: data.turn,
					step: data.step,
					// messageId 供消息反馈（👍/👎，对齐 PC 端 messageFeedback 服务）
					messageId: message.id,
					text: clampText(blocksToText(message.content), 20000),
					reasoningChars: reasoningChars(message.content),
					...(data.usage === void 0 ? {} : { usage: data.usage }),
				},
			};
		}
		case "assistant/chunk": {
			const chunk = data.chunk;
			if (chunk.type === "text-delta") return { seq, type, data: { turn: data.turn, step: data.step, text: clampText(chunk.text, 4000) } };
			if (chunk.type === "reasoning-delta") return { seq, type, data: { turn: data.turn, step: data.step, reasoning: true, text: clampText(chunk.text, 4000) } };
			if (chunk.type === "tool-call-delta") return { seq, type, data: { turn: data.turn, step: data.step, toolCall: chunk.name ?? "", argumentsDelta: clampText(chunk.argumentsDelta, 2000) } };
			return { seq, type, data: null }; // block-start/block-end/usage/finish：前端忽略
		}
		case "tool/call":
			return { seq, type, data: { turn: data.turn, step: data.step, callId: data.callId, name: data.name, arguments: clampText(data.arguments, 2000) } };
		case "tool/result": {
			const block = data.message?.content?.[0];
			return {
				seq,
				type,
				data: {
					turn: data.turn,
					step: data.step,
					callId: block?.toolCallId ?? "",
					name: data.error?.name ?? block?.toolCallId ?? "tool",
					isError: data.error !== undefined || block?.isError === true,
					text: clampText(blocksToText(block?.content ?? []), 2000),
				},
			};
		}
		case "turn/start":
			return { seq, type, data: { turn: data.turn } };
		case "turn/end":
			return { seq, type, data: { turn: data.turn, reason: data.reason } };
		default:
			return { seq, type };
	}
}

/** 与 PC 端设置页一致的凭据引用派生规则（v2.6）：路由 id 大写 → `<ID>_API_KEY`。 */
function deriveKeyRef(provider) {
	return `${String(provider).toUpperCase().replace(/[^A-Z0-9]+/g, "_")}_API_KEY`;
}

/** 插件主体。 */
export function apply(ctx, config) {
	const basePath = config.path;
	const authEnabled = config.authToken !== "";
	if (!authEnabled) {
		ctx.logger.warn(
			"mobile-remote: 访问口令（authToken）未启用——同一网络内任何设备都能连接并控制 agent，建议立即配置强口令（见 docs/04-security.md）"
		);
	}

	// ── 移动端动作注册表服务（插件契约 v0.1，docs/03-api.md §6.8） ──
	const actionEntries = new Map();
	const mobileActions = {
		register(spec) {
			if (typeof spec?.id !== "string" || spec.id === "") throw new Error("mobile-actions: action id must be a non-empty string");
			if (actionEntries.has(spec.id)) throw new Error(`mobile-actions: duplicate action id "${spec.id}"`);
			if (typeof spec?.handler !== "function") throw new Error(`mobile-actions: action "${spec.id}" needs a handler`);
			actionEntries.set(spec.id, {
				id: spec.id,
				title: String(spec.title ?? spec.id),
				icon: String(spec.icon ?? "zap"),
				fields: Array.isArray(spec.fields) ? spec.fields : [],
				handler: spec.handler,
			});
		},
		unregister(id) {
			actionEntries.delete(id);
		},
		list() {
			return [...actionEntries.values()].map(({ id, title, icon, fields }) => ({ id, title, icon, fields }));
		},
	};
	ctx.provide("mobileActions", mobileActions);

	// ── 通知中心：事件流聚合 + 已读持久化（文件，不用 settings 服务——无 fiber 的 HTTP 回调里调 settings 会崩进程） ──
	const READ_FILE = join(homedir(), ".dsh", "mobile-remote", "read-notifs.json");
	const notifStore = new Map(); // id -> { kind, sessionId, title, detail, time }
	const readIds = new Set();
	// v2.7.1：休眠会话标题折叠缓存（折叠需逐个读日志，50+ 会话可达数秒）；
	// 缓存 5 分钟，归档/取消归档后的列表刷新直接命中秒回。
	const titleCache = new Map(); // sessionId -> { title: string|null, at: ms }
	const TITLE_CACHE_TTL = 5 * 60 * 1000;
	const NOTIF_MAX = 100;
	let catalogCache = null; // { at, body } 15 秒 TTL
	let balanceCache = null; // { at, body } 余额缓存 60 秒 TTL（官方 API 抖动时兜底）
	// 插件自身版本（package.json 读取缓存，bootstrap/诊断共用）
	let pluginVersionCache = null;
	const pluginVersion = () => {
		if (pluginVersionCache === null) {
			try {
				pluginVersionCache = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version ?? "unknown";
			} catch {
				pluginVersionCache = "unknown";
			}
		}
		return pluginVersionCache;
	};
	const loadReadIds = () => {
		try {
			const raw = readFileSync(READ_FILE, "utf8");
			const doc = JSON.parse(raw);
			if (doc && Array.isArray(doc.readNotifs)) {
				readIds.clear();
				for (const id of doc.readNotifs) readIds.add(String(id));
			}
		} catch {
			// 文件不存在或损坏：保持内存态
		}
	};
	const persistReadIds = () => {
		try {
			mkdirSync(join(homedir(), ".dsh", "mobile-remote"), { recursive: true });
			const tmp = READ_FILE + ".tmp";
			writeFileSync(tmp, JSON.stringify({ readNotifs: [...readIds] }), "utf8");
			renameSync(tmp, READ_FILE);
		} catch {
			// 写入失败仅影响已读持久化，不影响其他功能
		}
	};

	// ── 会话活跃时间（插件本地持久化）；归档状态直接使用内核 workspaceRegistry（与 PC 端同一份） ──
	const ACTIVITY_FILE = join(homedir(), ".dsh", "mobile-remote", "session-activity.json");
	const activityMap = new Map(); // sessionId -> lastActivity(ms)
	const contextWindowMap = new Map(); // sessionId -> 模型上下文窗口（request/context 事件，PC 圆环同源）
	let activityPersistTimer = null;
	const loadMetaFiles = () => {
		try {
			const doc = JSON.parse(readFileSync(ACTIVITY_FILE, "utf8"));
			if (doc && typeof doc === "object") {
				activityMap.clear();
				for (const [k, v] of Object.entries(doc)) {
					if (typeof v === "number" && Number.isFinite(v)) activityMap.set(String(k), v);
				}
			}
		} catch {
			// 文件不存在或损坏：保持内存态
		}
	};
	const persistActivityNow = () => {
		try {
			mkdirSync(join(homedir(), ".dsh", "mobile-remote"), { recursive: true });
			const tmp = ACTIVITY_FILE + ".tmp";
			writeFileSync(tmp, JSON.stringify(Object.fromEntries(activityMap)), "utf8");
			renameSync(tmp, ACTIVITY_FILE);
		} catch {
			// 写入失败仅影响活跃时间持久化
		}
	};
	/** 内核归档集合（与 PC 端共享的同一份状态）。 */
	const coreArchivedIds = () => {
		const registry = ctx.get("workspaceRegistry");
		const ids = registry?.archivedSessionIds;
		return new Set(Array.isArray(ids) ? ids.map(String) : []);
	};
	/** 恢复（取消归档）：直接改内核 workspace 状态（内核暂无公开 unarchive RPC）。 */
	const unarchiveCore = async (sessionId) => {
		const registry = ctx.get("workspaceRegistry");
		if (!registry) throw Object.assign(new Error("workspace registry unavailable"), { status: 503 });
		await registry.enqueueOperation(async () => {
			const state = registry.requireState();
			await registry.setState({
				...state,
				archivedSessionIds: state.archivedSessionIds.filter((id) => id !== sessionId),
			});
		});
	};
	/** 记录会话活跃时间（去抖落盘：高频 chunk 只更新内存，静默 10 秒后写文件）。 */
	const touchActivity = (sessionId) => {
		if (typeof sessionId !== "string" || sessionId === "") return;
		activityMap.set(sessionId, Date.now());
		if (activityPersistTimer) return;
		activityPersistTimer = setTimeout(() => {
			activityPersistTimer = null;
			persistActivityNow();
		}, 10000);
		activityPersistTimer.unref?.();
	};
	const sessionTitleOf = (session) => {
		for (let i = session.events.length - 1; i >= 0; i--) {
			const event = session.events[i];
			if (event.type === "session/title") {
				const title = event.data?.title;
				if (typeof title === "string" && title !== "") return title;
			}
		}
		return undefined;
	};
	const pushNotification = (sessionId, kind, detail) => {
		const sessions = ctx.get("sessions");
		const session = sessions?.get(sessionId);
		const title = sessionTitleOf(session) ?? sessionId.slice(0, 8) + "…";
		const now = Date.now();
		// v2.7.1：每次完成独立一条通知（主会话/子代理各自成条，互不合并、不覆盖已读）——
		// 去掉旧"同会话同类型聚合"：读过的消息不再被后续轮次顶掉。
		const id = `${sessionId}:${kind}:${now}`;
		notifStore.set(id, { id, kind, sessionId, title, detail, time: now });
		if (notifStore.size > NOTIF_MAX) {
			const oldest = [...notifStore.keys()].sort((a, b) => notifStore.get(a).time - notifStore.get(b).time)[0];
			notifStore.delete(oldest);
		}
		// 通知变化即时广播：移动端铃铛角标/通知页实时刷新（v2.7 修复：之前仅重连/下拉才拉取）
		broadcast({ type: "notifications/changed" });
	};

	// ── 推送桥：多通道（serverchan / ntfy / bark / generic） ──
	const pushCooldowns = new Map(); // `${sessionId}:${kind}` -> last push time
	// v2.6.0 推送脱敏：minimal（默认）只推事件类型 + 会话短码，核心内容不进第三方通道；
	// standard 恢复旧行为（会话标题 + 事件详情），仅信任通道时开启。
	const pushMinimal = config.pushContent !== "standard";
	const pushSend = async (kind, sessionId, title, detail) => {
		if (config.pushUrls.length === 0) return;
		const key = `${sessionId}:${kind}`;
		const now = Date.now();
		const last = pushCooldowns.get(key) ?? 0;
		if (now - last < config.pushCooldownMs) return; // 节流
		pushCooldowns.set(key, now);
		const kindLabel = { completed: "✅ 任务完成", "needs-answer": "⚠ 需要你回答", failed: "❌ 任务失败" }[kind] ?? kind;
		const shortId = sessionId.length > 12 ? `${sessionId.slice(0, 8)}…${sessionId.slice(-4)}` : sessionId;
		const redactedTitle = pushMinimal ? shortId : title;
		const redactedDetail = pushMinimal ? "" : detail;
		for (const target of config.pushUrls) {
			await pushToChannel(target, kind, kindLabel, redactedTitle, redactedDetail, sessionId).catch((err) => {
				ctx.logger.warn(`mobile-remote: push to "${target.name}" failed: ${err?.message ?? err}`);
			});
		}
	};
	const pushToChannel = async (target, kind, kindLabel, title, detail, sessionId) => {
		const desp = detail || "详情请在 DSH Remote App 中查看";
		const url = target.url;
		const headers = { "user-agent": "dsh-mobile-remote" };
		let init;
		if (target.format === "serverchan") {
			// Server酱³：POST form，title/desp
			const params = new URLSearchParams({ title: `${kindLabel} · ${title}`, desp });
			init = { method: "POST", headers: { ...headers, "content-type": "application/x-www-form-urlencoded" }, body: params.toString() };
		} else if (target.format === "ntfy") {
			// ntfy JSON 格式：标题走 body（x-title 头只接受 Latin-1，中文/emoji 会抛错）
			init = { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ title: `${kindLabel} · ${title}`, message: desp }) };
		} else if (target.format === "bark") {
			init = { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ title: `${kindLabel} · ${title}`, body: desp }) };
		} else {
			init = { method: "POST", headers: { ...headers, "content-type": "application/json" }, body: JSON.stringify({ kind, title, detail: desp, sessionId, time: Date.now() }) };
		}
		const response = await fetch(url, { ...init, signal: AbortSignal.timeout(10_000) });
		if (!response.ok) throw new Error(`HTTP ${response.status}`);
	};

	/** 本机非 internal IPv4（含 Tailscale 100.x 段）。
	 *  过滤虚拟网卡：VMware/VMnet、Hyper-V vEthernet、代理虚拟网（198.18.0.0/15，Clash TUN 等），
	 *  以及链路本地地址（169.254.0.0/16，未登录的 Tailscale/断网网卡会产生，手机不可达），
	 *  避免把不可达地址（如 198.18.0.1、169.254.x.x）当成首选扫码地址。 */
	const ipv4Addresses = () =>
		Object.entries(networkInterfaces())
			.flatMap(([name, addrs]) => (addrs ?? []).map((iface) => ({ name, iface })))
			.filter(({ name, iface }) => {
				if (iface.family !== "IPv4" || iface.internal) return false;
				if (/vmnet|vethernet|virtualbox|vmware/i.test(name)) return false;
				const octets = iface.address.split(".").map(Number);
				if (octets.length === 4 && octets[0] === 198 && (octets[1] === 18 || octets[1] === 19)) return false;
				if (octets.length === 4 && octets[0] === 169 && octets[1] === 254) return false;
				return true;
			})
			.map(({ iface }) => iface.address);
	/** 地址排序（二维码首选/自动收集顺序）：
	 *  0 = 家庭局域网常见段（192.168.x / 10.x）——二维码首选，保证在家扫码即连
	 *  1 = 组网常见段（172.16-31，蒲公英/ZeroTier 等虚拟网）
	 *  2 = Tailscale CGNAT（100.64/10）
	 *  3 = 其他。
	 *  原理：在家扫码时必须给手机可达的局域网地址；组网地址靠连接后自动收集，
	 *  避免"扫到组网 IP 而手机组网未开 → 黑洞"的连环故障。 */
	const privateFirst = (ips) =>
		[...ips].sort((a, b) => {
			const rank = (ip) => {
				const o = ip.split(".").map(Number);
				if (o.length !== 4) return 3;
				if (o[0] === 10 || (o[0] === 192 && o[1] === 168)) return 0;
				if (o[0] === 172 && o[1] >= 16 && o[1] <= 31) return 1;
				if (o[0] === 100 && o[1] >= 64 && o[1] <= 127) return 2;
				return 3;
			};
			return rank(a) - rank(b);
		});
	/** Host 校验白名单（与 dsh /api 信任围栏同思路，阻断 DNS 重绑定）。
	 *  = 回环 + 本机全部 internal IPv4（含 Tailscale/ZeroTier/WireGuard 虚拟网段）+ 显式配置的 `trustedHosts`（内网穿透中转）。 */
	const trustedHosts = () => new Set(["127.0.0.1", "localhost", ...ipv4Addresses(), ...config.trustedHosts]);

	// 常量时间比较：先 sha256 定长化再比较，消除"先比长度"的长度侧信道（v2.6.0）
	const tokenMatches = (given) => {
		const a = createHash("sha256").update(String(given ?? "")).digest();
		const b = createHash("sha256").update(config.authToken).digest();
		return timingSafeEqual(a, b);
	};
	const cookieToken = (req) => {
		const header = req.headers.cookie ?? "";
		for (const part of header.split(";")) {
			const eq = part.indexOf("=");
			if (eq === -1) continue;
			if (part.slice(0, eq).trim() === config.cookieName) return part.slice(eq + 1).trim();
		}
		return undefined;
	};
	const authorized = (req) => {
		if (!authEnabled) return true;
		if (tokenMatches(req.headers["x-mobile-token"])) return true;
		return tokenMatches(cookieToken(req));
	};
	const hostAllowed = (req) => {
		const host = String(req.headers.host ?? "").toLowerCase();
		const hostname = host.startsWith("[") ? host.slice(1, host.indexOf("]")) : host.split(":")[0];
		return trustedHosts().has(hostname);
	};

	// ── 登录限流（v2.6.0）：按来源 IP 固定窗口计数，防弱口令爆破 ──
	// 正常用户一次成功即重置计数；frp 等中继场景所有外部请求同源（中继 IP），
	// 阈值 10 次/60s 对单用户足够宽裕（见 docs/04-security.md §2）。
	const rateLimitCfg = { maxFailures: 10, windowMs: 60_000, blockMs: 60_000, ...(config.rateLimit ?? {}) };
	const rateBuckets = new Map(); // ip -> { count, windowStart }
	const rateBlocked = (ip) => {
		const now = Date.now();
		const b = rateBuckets.get(ip);
		return b !== undefined && now - b.windowStart < rateLimitCfg.windowMs && b.count >= rateLimitCfg.maxFailures;
	};
	const rateFail = (ip) => {
		const now = Date.now();
		const b = rateBuckets.get(ip);
		if (!b || now - b.windowStart >= rateLimitCfg.windowMs) {
			rateBuckets.set(ip, { count: 1, windowStart: now });
		} else {
			b.count++;
		}
		// 防内存膨胀：超过 512 个来源时清掉最旧的一半
		if (rateBuckets.size > 512) {
			const oldest = [...rateBuckets.entries()]
				.sort((x, y) => x[1].windowStart - y[1].windowStart)
				.slice(0, 256)
				.map(([k]) => k);
			for (const k of oldest) rateBuckets.delete(k);
		}
	};
	const rateReset = (ip) => rateBuckets.delete(ip);

	const sendJson = (res, status, body, headers = {}) => {
		const text = JSON.stringify(body);
		res.writeHead(status, {
			"content-type": "application/json; charset=utf-8",
			"cache-control": "no-store",
			"content-length": Buffer.byteLength(text),
			...headers,
		});
		res.end(text);
	};
	const error = (res, status, err, detail) => sendJson(res, status, detail ? { error: err, detail } : { error: err });
	const readBody = (req, limit = 64 * 1024) =>
		new Promise((resolve, reject) => {
			let size = 0;
			const chunks = [];
			req.on("data", (chunk) => {
				size += chunk.length;
				if (size > limit) {
					reject(Object.assign(new Error("body too large"), { status: 413 }));
					req.destroy();
					return;
				}
				chunks.push(chunk);
			});
			req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
			req.on("error", reject);
		});

	// ── SSE 事件桥 ──────────────────────────────────────────────
	const connections = new Set();
	const dropConn = (res) => {
		connections.delete(res);
		try {
			res.destroy();
		} catch {
			// 已销毁
		}
	};
	const broadcast = (frame) => {
		const line = `data: ${JSON.stringify(frame)}\n\n`;
		for (const res of connections) {
			try {
				res.write(line);
			} catch {
				// 写失败（半开/客户端已死）→ 立即清理僵尸连接，避免占用 maxConnections 配额
				dropConn(res);
			}
		}
	};
	// ── v2.7 任务（jobs）视图：与 PC 端 GUI 同源（apiproxy 模式）──
	// 内核任务注册表（ctx.jobs）按会话（agent）隔离；任务视图随 session/jobs 帧下发。
	const jobViews = (list) =>
		(list ?? []).map((job) => ({
			id: job.id,
			kind: job.kind ?? "task",
			label: job.label ?? job.kind ?? job.id,
			status: job.status,
			...(job.startedAt === undefined ? {} : { startedAt: job.startedAt }),
			...(job.finishedAt === undefined ? {} : { finishedAt: job.finishedAt }),
		}));
	const sessionJobsFrames = () => {
		const agents = ctx.get("agents");
		const jobs = ctx.get("jobs");
		const sessions = ctx.get("sessions");
		if (!agents || !jobs || !sessions) return [];
		const out = [];
		for (const session of sessions.list?.() ?? []) {
			const agent = agents.get(session.id);
			if (!agent) continue;
			const views = jobViews(jobs.list(agent));
			if (views.length > 0) out.push({ type: "session/jobs", sessionId: session.id, jobs: views });
		}
		return out;
	};
	// ── 问询/审批桥（移动端弹窗）：rpcId → frame 待答清单，App 重连时补发 ──
	let proxy = null; // ctx.get("apiProxy")（含 respond / events.mux）
	const pendingFrames = new Map(); // `q:${rpcId}` / `a:${approvalId}` -> { rpcId, ...frame }
	let frameAbort = null; // 卸载时终止 mux 消费循环

	const connect = (res) => {
		if (connections.size >= config.maxConnections) {
			res.writeHead(503, { "content-type": "application/json; charset=utf-8" });
			res.end(JSON.stringify({ error: "too-many-connections" }));
			return;
		}
		res.writeHead(200, {
			"content-type": "text/event-stream",
			"cache-control": "no-cache",
			"connection": "keep-alive",
		});
		res.write(": connected\n\n");
		res.write(`data: ${JSON.stringify({ type: "hello", serverTime: Date.now() })}\n\n`);
		connections.add(res);
		// 补发断线期间挂起的问询/审批（与 PC 端 GUI 连接时的 pending 回放一致）
		for (const f of pendingFrames.values()) {
			res.write(`data: ${JSON.stringify({ type: "mobile/frame", frame: f })}\n\n`);
		}
		// v2.7：连接回放各会话任务视图（与 PC 端 GUI 同源）
		for (const f of sessionJobsFrames()) {
			res.write(`data: ${JSON.stringify(f)}\n\n`);
		}
		res.on("close", () => connections.delete(res));
		// 半开连接：客户端进程被杀/断网后 close 可能迟迟不来，error 事件立即清理僵尸
		res.on("error", () => connections.delete(res));
	};
	const onSessionEvent = (session, event) => {
		broadcast({ type: "session/event", sessionId: session.id, event: summarizeEvent(event) });
		// 会话有动静 = 标题可能变化：使该会话的标题缓存失效（活跃会话本就实时取标题，
		// 休眠会话不受影响——它没有实时事件流）
		titleCache.delete(session.id);
		// 任意会话事件都算活跃（"最近会话"排序依据），高频 chunk 只是内存更新
		touchActivity(session.id);
		// 上下文窗口：request/context 事件携带模型上下文大小（PC 端圆环同源数据）
		if (event.type === "request/context" && Number.isInteger(event.data?.contextWindow)) {
			contextWindowMap.set(session.id, event.data.contextWindow);
			// 实时推送：移动端圆环随每轮请求即时更新，无需重进会话
			broadcast({ type: "session/context", sessionId: session.id, contextWindow: event.data.contextWindow });
		}
		// 通知聚合：turn/end 分类（completed / failed / needs-answer）
		if (event.type === "turn/end") {
			const reason = event.data?.reason;
			const kind = reason?.kind;
			let notifKind;
			let detail;
			if (kind === "completed" || kind === "max-tokens") {
				notifKind = "completed";
				detail = `任务完成（轮次 ${event.data.turn}）`;
			} else if (kind === "error" || kind === "interrupted" || kind === "aborted") {
				notifKind = "failed";
				detail = kind === "error" && typeof reason?.error?.message === "string"
					? `任务失败：${reason.error.message.slice(0, 120)}`
					: `任务${kind === "aborted" ? "已取消" : "失败"}（轮次 ${event.data.turn}）`;
			} else if (kind === "blocked") {
				notifKind = "needs-answer";
				detail = "agent 正在等待你的回答";
			}
			if (notifKind) {
				pushNotification(session.id, notifKind, detail);
				// 推送桥：同一事件也触发手机系统通知（配置了 pushUrls 时）
				const sessions = ctx.get("sessions");
				const sess = sessions?.get(session.id);
				pushSend(notifKind, session.id, sessionTitleOf(sess) ?? session.id.slice(0, 8) + "…", detail);
			}
		}
	};
	const onAgentStatus = (payload) => {
		broadcast({ type: "agent/status", agentId: payload.agent.id, status: payload.status });
	};

	// ── HTTP 处理器 ─────────────────────────────────────────────
	const serveQr = async (req, res, url) => {
		if (req.method !== "GET" && req.method !== "HEAD") {
			error(res, 405, "method-not-allowed");
			return;
		}
		// v2.6.0：与 qr-config 同策略——仅电脑本机可访问（桌面设置页本就要求 loopback 才能拉到数据）
		if (!hostAllowed(req)) {
			error(res, 403, "host-not-allowed");
			return;
		}
		const remote = String(req.socket.remoteAddress ?? "");
		const loopback = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
		if (!loopback) {
			error(res, 403, "loopback-only", "仅电脑本机可访问");
			return;
		}
		const text = url.searchParams.get("text");
		if (!text) {
			error(res, 400, "bad-request", "missing ?text=");
			return;
		}
		try {
			const buffer = await QRCode.toBuffer(text, { width: 512, margin: 1, errorCorrectionLevel: "M" });
			res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
			res.end(buffer);
		} catch {
			error(res, 400, "bad-request", "qr encode failed");
		}
	};

	// ── 移动端 v2 公共 helper ─────────────────────────────────────
	/** 通过 /api 桥调用 PC 端 Remote（与浏览器 GUI 同一 HTTP 协议，loopback 在信任围栏内）。 */
	const apiRpc = async (method, payload) => {
		const port = ctx.webServer.port;
		const response = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ type: "client-request", rpcId: randomUUID(), method, payload }),
			signal: AbortSignal.timeout(15000),
		});
		if (!response.ok) throw Object.assign(new Error(`rpc transport failed: HTTP ${response.status}`), { status: 502 });
		const full = await response.json();
		if (!full?.result?.ok) throw Object.assign(new Error(full?.result?.error?.message ?? `${method} failed`), { status: 400 });
		return full.result.value;
	};
	/** 折叠会话事件的 agent 预设（agent-preset/selected，无则 undefined）。 */
	const foldAgentPreset = (session) => {
		for (let i = session.events.length - 1; i >= 0; i--) {
			const event = session.events[i];
			if (event.type === "agent-preset/selected") return event.data?.agentPreset;
		}
		return undefined;
	};
	/** 应用权限预设（workspace-write / danger-full-access 走 preset 服务，read-only 走 sandbox 事件）。 */
	const applyPermissionPreset = (session, preset) => {
		const permissionPresets = ctx.get("permissionPresets");
		const agents = ctx.get("agents");
		const agent = agents?.get(session.id);
		if (preset === "read-only") {
			setSandboxMode(session, "read-only");
			return;
		}
		if (!permissionPresets) throw Object.assign(new Error("permission service unavailable"), { status: 503 });
		if (!permissionPresets.names.includes(preset)) throw Object.assign(new Error(`unknown permission preset "${preset}"`), { status: 400 });
		const approval = ctx.get("approval");
		permissionPresets.apply(session, preset, (policy) => {
			if (approval && agent) approval.setPolicy(agent, policy);
		});
	};
	/** 读取一个会话的当前配置（模型/推理/权限/预设），失败字段降级为 undefined。 */
	const readSessionConfig = async (sessionId) => {
		const config = { model: undefined, provider: undefined, reasoningEffort: undefined, permissionPreset: undefined, agentPreset: undefined };
		const sessions = ctx.get("sessions");
		const session = sessions?.get(sessionId);
		try {
			const models = await apiRpc("session.models", { sessionId });
			config.model = models?.current?.model;
			config.provider = models?.current?.provider;
			config.reasoningEffort = models?.current?.reasoningEffort;
		} catch (err) {
			ctx.logger.warn(`mobile-remote: session.models RPC failed: ${err?.message ?? err}`);
		}
		if (session) {
			const permissionPresets = ctx.get("permissionPresets");
			try {
				config.permissionPreset = permissionPresets?.current(session.events);
			} catch {
				// 保持 undefined
			}
			config.agentPreset = foldAgentPreset(session);
		}
		return config;
	};

	const handleApi = async (req, res, url, rest) => {
		if (!hostAllowed(req)) {
			error(res, 403, "host-not-allowed");
			return;
		}
		const method = req.method;
		// qr-config 供桌面 GUI（loopback）拉取二维码数据，豁免统一鉴权；其余端点统一鉴权。
		// v2.6.0：口令启用时叠加登录限流——失败按来源 IP 计数，成功即重置。
		if (rest !== "/qr-config") {
			if (authEnabled) {
				const ip = String(req.socket.remoteAddress ?? "");
				if (rateBlocked(ip)) {
					sendJson(
						res,
						429,
						{ error: "rate-limited", detail: "尝试次数过多，请稍后再试" },
						{ "retry-after": String(Math.ceil(rateLimitCfg.blockMs / 1000)) }
					);
					return;
				}
				if (!authorized(req)) {
					rateFail(ip);
					error(res, 401, "auth-required", "访问口令未通过验证");
					return;
				}
				rateReset(ip);
			} else if (!authorized(req)) {
				error(res, 401, "auth-required", "认证未启用");
				return;
			}
		}

		if (rest === "/bootstrap") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const agents = ctx.get("agents");
			const sessions = ctx.get("sessions");
			const agentList = agents
				? agents.list().map((agent) => ({ id: agent.id, status: agent.status, hasPending: agent.inbox.hasPending }))
				: [];
			const sessionList = sessions
				? sessions.list().map((session) => ({ id: session.id, createdAt: session.header.createdAt, cwd: session.header.cwd }))
				: [];
			const urls = [...privateFirst(ipv4Addresses()), "127.0.0.1"].map((ip) => `http://${ip}:${ctx.webServer.port}`);
			sendJson(res, 200, {
				ok: true,
				auth: { enabled: authEnabled },
				server: { port: ctx.webServer.port, urls },
				plugin: { name: "dsh-mobile-remote", version: pluginVersion() },
				agents: agentList,
				sessions: sessionList,
			});
			return;
		}

		if (rest === "/qr-config") {
			// 桌面 GUI（dsh 设置页客户端模块）拉取"连接移动端设备"二维码数据。
			// 仅允许电脑本机（TCP 层 socket 来源，无法伪造）；二维码内容含访问口令，
			// 必须确保它只在桌面屏幕上展示。
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const remote = String(req.socket.remoteAddress ?? "");
			const loopback = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
			if (!loopback) return error(res, 403, "loopback-only", "仅电脑本机可访问");
			sendJson(res, 200, {
				ok: true,
				urls: [...privateFirst(ipv4Addresses()), "127.0.0.1"].map((ip) => `http://${ip}:${ctx.webServer.port}${basePath}`),
				token: config.authToken,
				path: basePath,
			});
			return;
		}

		if (rest === "/send") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			const text = body?.text;
			if (typeof text !== "string" || text.trim() === "") return error(res, 400, "empty-text");
			const agents = ctx.get("agents");
			if (!agents) return error(res, 503, "agents-unavailable");
			const sessionId = typeof body?.sessionId === "string" && body.sessionId ? body.sessionId : undefined;
			const target = sessionId ? agents.get(sessionId) : agents.roots()[0];
			if (!target) return error(res, sessionId ? 404 : 503, sessionId ? "session-not-found" : "no-live-agent");
			const message = createUserMessage({ content: [{ type: "text", text }], source: { kind: "user" } });
			target.followup(message);
			sendJson(res, 200, { ok: true, agentId: target.id, messageId: message.id });
			return;
		}

		if (rest === "/sessions" && method === "POST") {
			// 新建会话（移动端 v2）
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			const agents = ctx.get("agents");
			if (!agents) return error(res, 503, "agents-unavailable");
			// 工作目录：对齐 PC 端 session.create 优先级
			// 请求参数 cwd → 当前 workspace 根 → 活跃会话工作目录 → 进程目录
			let cwd;
			try {
				if (typeof body.cwd === "string" && body.cwd !== "") cwd = body.cwd;
				if (!cwd) {
					const registry = ctx.get("workspaceRegistry");
					const workspaces = registry?.list?.();
					if (workspaces && workspaces.length > 0) cwd = workspaces[0].path;
				}
				if (!cwd) {
					for (const agent of agents.list()) {
						if (agent.session?.header?.cwd) { cwd = agent.session.header.cwd; break; }
					}
				}
				if (!cwd) cwd = process.cwd();
			} catch {
				cwd = process.cwd();
			}
			const agentPresets = ctx.get("agentPresets");
			let preset = typeof body.preset === "string" && body.preset !== "" ? body.preset : undefined;
			if (preset === undefined && agentPresets) preset = agentPresets.defaultId;
			if (preset === undefined) return error(res, 400, "invalid-preset", "no preset available");
			const sessionId = randomUUID();
			try {
				const handle = await agents.create({
					sessionId,
					meta: { cwd, agentPreset: preset },
					agentOptions: {
						...(typeof body.provider === "string" ? { provider: body.provider } : {}),
						...(typeof body.model === "string" ? { model: body.model } : {}),
					},
				});
				try {
					if (typeof body.model === "string") {
						await apiRpc("session.selectModel", {
							sessionId,
							provider: typeof body.provider === "string" ? body.provider : "deepseek-official",
							model: body.model,
							...(body.reasoningEffort === undefined ? {} : { reasoningEffort: body.reasoningEffort }),
						});
					} else if (body.reasoningEffort !== undefined) {
						const config = await readSessionConfig(sessionId);
						if (config.model) {
							await apiRpc("session.selectModel", {
								sessionId,
								provider: "deepseek-official",
								model: config.model,
								reasoningEffort: body.reasoningEffort,
							});
						}
					}
					if (typeof body.permissionPreset === "string") {
						if (body.permissionPreset === "danger-full-access" && body.confirmDanger !== true) {
							return error(res, 400, "risk-confirmation-required", "选择完全访问需显式确认风险");
						}
						applyPermissionPreset(handle.agent.session, body.permissionPreset);
					}
				} catch {
					// 会话已创建成功，附加配置失败不阻断创建
				}
				// attach 到匹配的工作区（PC 端 GUI 按工作区分组显示会话）
				try {
					const registry = ctx.get("workspaceRegistry");
					if (registry && cwd) {
						let workspace = await registry.resolveByPath?.(cwd);
						if (!workspace) {
							// 子路径归属：cwd 不在任何已注册工作区根时，逐级向上找最近已注册
							// 工作区（如新建文件夹位于某工作区下），避免会话落入"未分组"。
							const sep = cwd.includes("\\") ? "\\" : "/";
							let p = cwd;
							while (p.includes(sep)) {
								p = p.slice(0, p.lastIndexOf(sep));
								if (!p || p.length <= 2) break; // 到盘符根为止
								try {
									workspace = await registry.resolveByPath?.(p);
									if (workspace) break;
								} catch {
									break;
								}
							}
						}
						workspace?.attachSession(sessionId);
					}
				} catch {
					// attach 失败不影响会话本身
				}
				sendJson(res, 200, { ok: true, sessionId, agentId: handle.agent.id, preset });
			} catch (err) {
				return error(res, 500, "session-create-failed", err.message);
			}
			return;
		}

		if (rest === "/sessions") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const sessions = ctx.get("sessions");
			if (!sessions) return error(res, 503, "sessions-unavailable");
			// 优先用 sessionQuery 列完整语料（含 PC 端新建但未激活 agent 的休眠会话）；
			// 回退 sessions.list()（仅活动会话）。
			const query = ctx.get("sessionQuery");
			let records = null;
			try {
				if (query?.listSessions) records = await query.listSessions();
			} catch {
				records = null;
			}
			const list = [];
			const archived = coreArchivedIds();
			if (records) {
				// 休眠会话（内核内存无 agent 实例）从持久化日志折叠标题——
				// v2.7.1：折叠很贵（逐个读日志，50+ 会话可达数秒），结果缓存 5 分钟，
				// 归档/取消归档后的列表刷新直接命中缓存秒回（不再每次重算）。
				const dormant = records.filter((r) => !sessions.get(r.header.id));
				const titleMap = new Map();
				const now = Date.now();
				const toFold = dormant.filter((r) => {
					const c = titleCache.get(r.header.id);
					if (c && now - c.at < TITLE_CACHE_TTL) {
						if (c.title) titleMap.set(r.header.id, c.title);
						return false;
					}
					return true;
				});
				if (toFold.length > 0 && query?.readTitleSnapshots) {
					try {
						const snaps = await query.readTitleSnapshots(toFold.map((r) => r.header.id));
						toFold.forEach((r, i) => {
							const s = snaps?.[i];
							const t = s?.status === 'fulfilled' ? s.value?.title?.title : undefined;
							if (t) {
								titleMap.set(r.header.id, t);
								titleCache.set(r.header.id, { title: t, at: now });
							} else {
								// 无标题也缓存（避免每次列表刷新重复折叠同一批冷会话）
								titleCache.set(r.header.id, { title: null, at: now });
							}
						});
					} catch {
						// 批量失败则逐个兜底（同样写缓存）
						for (const r of toFold) {
							try {
								const snap = await query.readTitleSnapshot?.(r.header.id);
								const t = snap?.title?.title;
								if (t) {
									titleMap.set(r.header.id, t);
									titleCache.set(r.header.id, { title: t, at: now });
								} else {
									titleCache.set(r.header.id, { title: null, at: now });
								}
							} catch {
								/* 忽略 */
							}
						}
					}
				} else if (toFold.length > 0 && query?.readTitleSnapshot) {
					for (const r of toFold) {
						try {
							const snap = await query.readTitleSnapshot(r.header.id);
							const t = snap?.title?.title;
							if (t) {
								titleMap.set(r.header.id, t);
								titleCache.set(r.header.id, { title: t, at: now });
							} else {
								titleCache.set(r.header.id, { title: null, at: now });
							}
						} catch {
							/* 忽略 */
						}
					}
				}
				for (const r of records) {
					const live = sessions.get(r.header.id);
					let title = live ? sessionTitleOf(live) : titleMap.get(r.header.id);
					list.push({
						id: r.header.id,
						createdAt: r.header.createdAt,
						cwd: r.header.cwd,
						live: r.live,
						title,
						archived: archived.has(r.header.id),
						lastActivity: activityMap.get(r.header.id) ?? null,
					});
				}
			} else {
				for (const session of sessions.list()) {
					list.push({
						id: session.id,
						createdAt: session.header.createdAt,
						cwd: session.header.cwd,
						live: true,
						title: sessionTitleOf(session),
						archived: archived.has(session.id),
						lastActivity: activityMap.get(session.id) ?? null,
					});
				}
			}
			// 最近活跃优先（无活跃记录回退创建时间）
			list.sort((a, b) => (b.lastActivity ?? b.createdAt) - (a.lastActivity ?? a.createdAt));
			sendJson(res, 200, { ok: true, sessions: list });
			return;
		}

		if (rest === "/sessions/touch") {
			// 标记会话被打开（移动端记录"最近打开"，与 SSE 事件活跃共同决定排序）
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			touchActivity(body.sessionId);
			persistActivityNow();
			sendJson(res, 200, { ok: true, lastActivity: activityMap.get(body.sessionId) });
			return;
		}

		if (rest === "/sessions/archive" || rest === "/sessions/unarchive") {
			// 归档/恢复会话：直接读写内核 workspaceRegistry 的归档状态（与 PC 端同一份）。
			// 归档后仍在列表返回中（archived: true），由客户端过滤展示。
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			const archive = rest === "/sessions/archive";
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			try {
				if (archive) {
					await apiRpc("workspace.archiveSession", { sessionId: body.sessionId });
				} else {
					await unarchiveCore(body.sessionId);
				}
			} catch (err) {
				return error(res, err?.status ?? 500, err?.status ? (err.code ?? "archive-failed") : "archive-failed", err?.message ?? "archive failed");
			}
			sendJson(res, 200, { ok: true, archived: archive });
			return;
		}

		if (rest === "/sessions/fork") {
			// 在新对话中分支：映射内核 session.fork（atSeq 锚定已完成轮次的切点）
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			try {
				const child = await apiRpc("session.fork", {
					sessionId: body.sessionId,
					...(typeof body.atSeq === "number" && Number.isFinite(body.atSeq) ? { atSeq: body.atSeq } : {}),
				});
				sendJson(res, 200, { ok: true, sessionId: child.sessionId });
			} catch (err) {
				return error(res, err?.status ?? 500, "fork-failed", err?.message ?? "fork failed");
			}
			return;
		}

		if (rest === "/feedback") {
			// 消息反馈（👍/👎）：直接调用内核 messageFeedback 服务（与 PC 端同一份数据）
			if (method === "GET" || method === "HEAD") {
				const sessionId = url.searchParams.get("sessionId");
				if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
				const service = ctx.get("messageFeedback");
				if (!service?.list) return error(res, 503, "feedback-unavailable");
				try {
					const result = await service.list({ sessionId });
					if (!result?.ok) return error(res, 404, "session-not-found", result?.error?.message);
					sendJson(res, 200, { ok: true, items: result.value.items });
				} catch (err) {
					return error(res, 500, "feedback-failed", err?.message ?? "feedback failed");
				}
				return;
			}
			if (method === "POST") {
				let body;
				try {
					body = JSON.parse(await readBody(req));
				} catch {
					return error(res, 400, "bad-request");
				}
				if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
				if (typeof body?.messageId !== "string" || body.messageId === "") return error(res, 400, "missing-messageId");
				if (body?.rating !== "positive" && body?.rating !== "negative") return error(res, 400, "invalid-rating");
				const service = ctx.get("messageFeedback");
				if (!service?.put) return error(res, 503, "feedback-unavailable");
				try {
					const result = await service.put({
						sessionId: body.sessionId,
						messageId: body.messageId,
						rating: body.rating,
						...(typeof body.ifVersion === "string" ? { ifVersion: body.ifVersion } : {}),
					});
					if (!result?.ok) {
						const code = result?.error?.code;
						return error(res, code === "target-not-found" ? 404 : 409, code ?? "feedback-failed", result?.error?.message ?? "feedback failed");
					}
					sendJson(res, 200, { ok: true, item: result.value });
				} catch (err) {
					return error(res, 500, "feedback-failed", err?.message ?? "feedback failed");
				}
				return;
			}
			return error(res, 405, "method-not-allowed");
		}

		if (rest === "/sessions/stop") {
			// 停止（取消）会话当前运行：对齐 PC 端"停止"按钮，映射 session.cancel
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			try {
				await apiRpc("session.cancel", { sessionId: body.sessionId });
			} catch (err) {
				return error(res, 500, "cancel-failed", err?.message ?? "cancel failed");
			}
			sendJson(res, 200, { ok: true, accepted: true });
			return;
		}

		if (rest === "/history") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const sessionId = url.searchParams.get("sessionId");
			if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
			const sessions = ctx.get("sessions");
			if (!sessions) return error(res, 503, "sessions-unavailable");
			let session = sessions.get(sessionId);
			// 休眠会话（持久化但未激活）：用 sessionQuery.readSession 读完整日志，不激活
			if (!session) {
				const query = ctx.get("sessionQuery");
				if (query?.readSession) {
					try {
						const snapshot = await query.readSession(sessionId);
						session = { events: snapshot.events };
					} catch {
						session = null;
					}
				}
			}
			if (!session) return error(res, 404, "session-not-found");
			const afterParam = url.searchParams.get("after");
			const beforeParam = url.searchParams.get("before");
			const limit = Math.min(Number(url.searchParams.get("limit") ?? 500) || 500, 1000);
			// 只保留表面事件（过滤 token 级 chunk 等海量日志型事件）
			const surface = session.events.filter((event) => SURFACE_TYPES.has(event.type));
			let events;
			if (afterParam !== null) {
				// 增量补漏：seq > after（SSE 重连后使用）
				const after = Number(afterParam) || 0;
				events = surface.filter((event) => event.seq > after).slice(0, limit);
			} else if (beforeParam !== null) {
				// 上翻分页：seq < before 的最近 limit 条（对话内往上翻加载更早）
				const before = Number(beforeParam) || Number.MAX_SAFE_INTEGER;
				events = surface.filter((event) => event.seq < before).slice(-limit);
			} else {
				// 初始加载：取最近 limit 条（尾部），避免从 seq 0 只拿到对话开头
				events = surface.slice(-limit);
			}
			sendJson(res, 200, {
				ok: true,
				sessionId,
				after: events.length ? events[events.length - 1].seq : 0,
				events: events.map(summarizeEvent),
			});
			return;
		}

		if (rest === "/events") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			connect(res);
			return;
		}

		// ── 移动端 v2：目录 / 配置 / 新建会话 / 通知 / 动作 ──
		if (rest === "/catalog") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			// 目录缓存（15 秒）：避免每次打开页面都重新探测模型/预设
			const now = Date.now();
			if (catalogCache && now - catalogCache.at < 15000) {
				sendJson(res, 200, catalogCache.body);
				return;
			}
			const agents = ctx.get("agents");
			const sessions = ctx.get("sessions");
			const firstAgent = agents?.roots()[0] ?? agents?.list()[0];
			const models = [];
			const reasoningEfforts = new Set();
			const pushModels = (provider, list) => {
				for (const model of list ?? []) {
					models.push({
						provider,
						id: model.id,
						name: model.name ?? model.id,
						...(model.description === void 0 ? {} : { description: model.description }),
						...(model.contextWindow === void 0 ? {} : { contextWindow: model.contextWindow }),
					});
					for (const effort of model.reasoning?.efforts ?? []) reasoningEfforts.add(effort.id);
				}
			};
			let providers = [];
			try {
				const llm = ctx.get("llm");
				if (firstAgent) {
					const directory = await apiRpc("session.models", { sessionId: firstAgent.id });
					for (const group of directory?.groups ?? []) pushModels(group.id, group.models);
				} else if (llm) {
					// 无运行中 agent：直接遍历全部提供商（v2.6 起不再写死 deepseek-official）
					for (const p of await llm.listProviders()) {
						pushModels(p.id, await llm.listModels(p.id));
					}
				}
				if (llm) {
					// 提供商元信息（显示名 + dormant 状态），供移动端分组显示
					let registered = [];
					let configurable = [];
					try {
						registered = await llm.listProviders();
						configurable = await llm.listConfigurableProviders();
					} catch {
						// 服务不可用：元信息留空（模型仍可显示）
					}
					const dormantIds = new Set(
						configurable.filter((c) => !registered.some((r) => r.id === c.provider)).map((c) => c.provider)
					);
					providers = [
						...registered.map((p) => ({ id: p.id, name: p.name, dormant: false })),
						...configurable
							.filter((c) => dormantIds.has(c.provider))
							.map((c) => ({ id: c.provider, name: c.displayName, dormant: true })),
					];
				}
			} catch {
				// 目录不可用时返回空列表，客户端显示"暂无模型"
			}
			const permissionPresets = ctx.get("permissionPresets");
			const presetEntries = permissionPresets
				? Object.entries(permissionPresets.presets).map(([id, spec]) => ({ id, name: spec.name ?? id, description: spec.description }))
				: [];
			const permissionList = [
				{ id: "read-only", name: "Read Only", description: "只读 · 拒绝一切写入操作" },
				...presetEntries.filter((entry) => entry.id !== "read-only"),
			];
			const agentPresets = [];
			try {
				const presets = ctx.get("agentPresets");
				if (presets) {
					for (const preset of await presets.list()) {
						agentPresets.push({ id: preset.id, name: preset.name ?? preset.id, description: preset.description ?? "" });
					}
				}
			} catch {
				// 预设目录不可用时返回空列表
			}
			const defaults = {
				model: firstAgent ? (await readSessionConfig(firstAgent.id)).model : undefined,
				reasoningEffort: firstAgent ? (await readSessionConfig(firstAgent.id)).reasoningEffort : undefined,
				permissionPreset: permissionPresets?.defaultSettings?.()?.defaultPreset,
				agentPreset: ctx.get("agentPresets")?.defaultId,
			};
			catalogCache = { at: now, body: {
				ok: true,
				models,
				providers,
				reasoningEfforts: [...reasoningEfforts],
				permissionPresets: permissionList,
				agentPresets,
				defaults,
				rechargeUrl: config.rechargeUrl,
			} };
			sendJson(res, 200, catalogCache.body);
			return;
		}

		// ── v2.6：模型提供商（与 PC 端 设置→模型 同一配置通道） ──
		if (rest === "/llm-providers") {
			const llm = ctx.get("llm");
			if (!llm) return error(res, 503, "llm-unavailable");
			const settings = ctx.get("settings");
			const credentials = ctx.get("credentials");
			if (method === "GET" || method === "HEAD") {
				let registered = [];
				let configurable = [];
				try {
					registered = await llm.listProviders();
					configurable = await llm.listConfigurableProviders();
				} catch {
					// 服务不可用：空列表
				}
				const rows = [];
				const seen = new Set();
				for (const p of registered) {
					rows.push({ id: p.id, name: p.name, dormant: false, settingsNs: null, settingsPath: [], baseURL: null, apiKeyRef: null, keyConfigured: false, keyWritable: false, catalogModels: null });
					seen.add(p.id);
				}
				for (const c of configurable) {
					const row = rows.find((r) => r.id === c.provider);
					const entry = row ?? { id: c.provider, name: c.displayName, dormant: true, settingsNs: c.settingsNs, settingsPath: c.settingsPath ?? [], baseURL: null, apiKeyRef: null, keyConfigured: false, keyWritable: false, catalogModels: null };
					entry.settingsNs = c.settingsNs;
					entry.settingsPath = c.settingsPath ?? [];
					if (settings && entry.settingsNs) {
						try {
							const section = settings.get(entry.settingsNs);
							let prof = section;
							for (const k of entry.settingsPath) prof = prof?.[k];
							if (prof && typeof prof === "object") {
								entry.baseURL = typeof prof.baseURL === "string" ? prof.baseURL : null;
								entry.apiKeyRef = typeof prof.apiKeyEnv === "string" && prof.apiKeyEnv !== "" ? prof.apiKeyEnv : null;
								entry.catalogModels = Array.isArray(prof.models)
									? prof.models.map((m) => ({ id: m.id, name: m.name ?? m.id }))
									: null;
							}
						} catch {
							// 命名空间未注册/不可读：保持空配置
						}
					}
					if (credentials && entry.apiKeyRef) {
						try {
							const info = await credentials.describe(credentialRef(entry.apiKeyRef));
							entry.keyConfigured = info?.configured ?? false;
							entry.keyWritable = info?.writable ?? false;
						} catch {
							// 凭据服务不可用：标记未配置
						}
					}
					if (row) Object.assign(row, entry);
					else rows.push(entry);
				}
				sendJson(res, 200, { ok: true, providers: rows });
				return;
			}
			if (method === "POST") {
				let body;
				try {
					body = JSON.parse(await readBody(req));
				} catch {
					return error(res, 400, "bad-request");
				}
				const provider = typeof body.provider === "string" ? body.provider : "";
				const ns = typeof body.settingsNs === "string" ? body.settingsNs : "";
				const baseURL = typeof body.baseURL === "string" ? body.baseURL.trim() : "";
				const apiKey = typeof body.apiKey === "string" ? body.apiKey.trim() : "";
				// 安全：只允许写入配置目录中声明的命名空间（防止任意 settings 写入）
				let configurable = [];
				try {
					configurable = await llm.listConfigurableProviders();
				} catch {
					// 目录不可用
				}
				const dir = configurable.find((c) => c.provider === provider && c.settingsNs === ns);
				if (!dir) return error(res, 400, "unknown-provider", "提供商不在可配置目录中");
				if (!settings) return error(res, 503, "settings-unavailable");
				if (baseURL === "") return error(res, 400, "baseURL-required");
				const path = dir.settingsPath ?? [];
				// 密钥引用：profile 已记录则沿用（与 PC 端一致），否则按 deriveKeyRef 派生
				let ref = null;
				let existingProfile = null;
				try {
					const section = settings.get(ns);
					let prof = section;
					for (const k of path) prof = prof?.[k];
					if (prof && typeof prof === "object") {
						existingProfile = prof;
						if (typeof prof.apiKeyEnv === "string" && prof.apiKeyEnv !== "") ref = prof.apiKeyEnv;
					}
				} catch {}
				// 模型归一化：接受 [{id, name?}] 或字符串数组
				const normalizeModels = (list) =>
					list
						.map((m) =>
							typeof m === "string"
								? { id: m }
								: { id: String(m?.id ?? ""), ...(typeof m?.name === "string" && m.name !== "" ? { name: m.name } : {}) }
						)
						.filter((m) => m.id !== "");
				const models = Array.isArray(body.models) && body.models.length > 0 ? normalizeModels(body.models) : null;
				let ops;
				if (path.length === 0) {
					// deepseek 风格（整节即 profile）：字段级补丁，保留其他配置
					ops = [{ op: "set", path: ["baseURL"], value: baseURL }];
					if (models) ops.push({ op: "set", path: ["models"], value: models });
					if (apiKey !== "" || body.removeKey === true) {
						if (!credentials) return error(res, 503, "credentials-unavailable");
						ref = ref ?? deriveKeyRef(provider);
						ops.push({ op: "set", path: ["apiKeyEnv"], value: ref });
						if (apiKey !== "") await credentials.set(credentialRef(ref), apiKey);
						else await credentials.unset(credentialRef(ref)).catch(() => {});
					}
				} else {
					// pi-ai 风格（providers.<route>）：整体 profile（与 PC 端 CustomProviderCard 同款形状）
					if (apiKey !== "" || body.removeKey === true) {
						if (!credentials) return error(res, 503, "credentials-unavailable");
						ref = ref ?? deriveKeyRef(provider);
						if (apiKey !== "") await credentials.set(credentialRef(ref), apiKey);
						else await credentials.unset(credentialRef(ref)).catch(() => {});
					}
					const profile = {
						...(existingProfile && typeof existingProfile === "object" ? existingProfile : {}),
						...(typeof body.displayName === "string" && body.displayName !== "" ? { displayName: body.displayName } : {}),
						...(typeof body.api === "string" && body.api !== "" ? { api: body.api } : {}),
						baseURL,
						...(models ? { models } : {}),
					};
					if (apiKey !== "" || body.removeKey === true) {
						if (apiKey !== "") profile.apiKeyEnv = ref;
						else delete profile.apiKeyEnv;
					}
					ops = [{ op: "set", path, value: profile }];
				}
				await settings.mutate(ns, ops);
				sendJson(res, 200, { ok: true, provider, apiKeyRef: ref, keyConfigured: apiKey !== "" });
				return;
			}
			return error(res, 405, "method-not-allowed");
		}

		if (rest === "/llm-providers/probe") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			const llm = ctx.get("llm");
			if (!llm) return error(res, 503, "llm-unavailable");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			const ns = typeof body.settingsNs === "string" ? body.settingsNs : "";
			const baseURL = typeof body.baseURL === "string" ? body.baseURL.trim() : "";
			const apiKey = typeof body.apiKey === "string" ? body.apiKey.trim() : "";
			if (ns === "" || baseURL === "") return error(res, 400, "bad-request", "settingsNs 与 baseURL 必填");
			// 安全：仅允许探测配置目录声明的命名空间
			let configurable = [];
			try {
				configurable = await llm.listConfigurableProviders();
			} catch {
				// 目录不可用
			}
			if (!configurable.some((c) => c.settingsNs === ns)) return error(res, 400, "unknown-namespace");
			try {
				let discovered = null;
				let usedFallback = false;
				try {
					discovered = await llm.discoverModels(ns, {
						baseURL,
						...(typeof body.protocol === "string" && body.protocol !== "" ? { protocol: body.protocol } : {}),
						...(apiKey !== "" ? { credential: apiKey } : {}),
					});
				} catch (err) {
					// 内核适配器未注册模型探测（rc.5 deepseek 适配器即如此）：
					// 回退 OpenAI 兼容 `GET {baseURL}/models` 探测（dormant 提供商均为 chat-completions 协议）
					if (String(err?.message ?? err).includes("no model discovery")) {
						usedFallback = true;
						const headers = { accept: "application/json", ...(apiKey !== "" ? { authorization: `Bearer ${apiKey}` } : {}) };
						const resp = await fetch(`${baseURL.replace(/\/+$/, "")}/models`, { headers, signal: AbortSignal.timeout(10_000) });
						if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
						const j = await resp.json();
						discovered = (Array.isArray(j?.data) ? j.data : []).map((m) => ({
							id: typeof m.id === "string" ? m.id : String(m.id ?? ""),
							...(typeof m.name === "string" ? { name: m.name } : {}),
							...(typeof m.contextWindow === "number" ? { contextWindow: m.contextWindow } : {}),
						}));
					} else {
						throw err;
					}
				}
				sendJson(res, 200, { ok: true, models: discovered ?? [], fallback: usedFallback });
			} catch (err) {
				return error(res, 400, "probe-failed", err?.message ?? String(err));
			}
			return;
		}

		if (rest === "/session-config") {
			let sessionId = url.searchParams.get("sessionId");
			let body;
			if (method === "POST") {
				try {
					body = JSON.parse(await readBody(req));
				} catch {
					return error(res, 400, "bad-request");
				}
				if (typeof body?.sessionId === "string") sessionId = body.sessionId;
			}
			if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
			if (method === "GET" || method === "HEAD") {
				const config = await readSessionConfig(sessionId);
				sendJson(res, 200, { ok: true, sessionId, config });
				return;
			}
			if (method === "POST") {
				const sessions = ctx.get("sessions");
				const session = sessions?.get(sessionId);
				if (!session) return error(res, 404, "session-not-found");
				if (body.model !== undefined || body.reasoningEffort !== undefined) {
					const provider = typeof body.provider === "string" ? body.provider : "deepseek-official";
					// 只改推理强度时：自动带上当前会话的模型（selectModel 需要完整选择）
					let model = typeof body.model === "string" && body.model !== "" ? body.model : undefined;
					if (model === undefined && body.reasoningEffort !== undefined) {
						const current = await readSessionConfig(sessionId);
						model = current.model;
					}
					if (model === undefined) return error(res, 400, "bad-request", "model required when selecting");
					try {
						await apiRpc("session.selectModel", {
							sessionId,
							provider,
							model,
							...(body.reasoningEffort === undefined ? {} : { reasoningEffort: body.reasoningEffort }),
						});
					} catch (err) {
						return error(res, err.status ?? 400, "model-select-failed", err.message);
					}
				}
				if (body.permissionPreset !== undefined) {
					if (body.permissionPreset === "danger-full-access" && body.confirmDanger !== true) {
						return error(res, 400, "risk-confirmation-required", "选择完全访问需显式确认风险");
					}
					try {
						applyPermissionPreset(session, body.permissionPreset);
					} catch (err) {
						return error(res, err.status ?? 400, "permission-apply-failed", err.message);
					}
				}
				const config = await readSessionConfig(sessionId);
				sendJson(res, 200, { ok: true, sessionId, config });
				return;
			}
			return error(res, 405, "method-not-allowed");
		}

		if (rest === "/notifications") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const items = [...notifStore.values()]
				.sort((a, b) => b.time - a.time)
				.map((n) => ({ ...n, unread: !readIds.has(n.id) }));
			sendJson(res, 200, { ok: true, unread: items.filter((n) => n.unread).length, items: items.slice(0, NOTIF_MAX) });
			return;
		}

		if (rest === "/notifications/read") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			if (body?.all === true) {
				for (const id of notifStore.keys()) readIds.add(id);
			} else if (Array.isArray(body?.ids)) {
				for (const id of body.ids) readIds.add(String(id));
			} else {
				return error(res, 400, "bad-request", "expected { ids } or { all: true }");
			}
			persistReadIds();
			sendJson(res, 200, { ok: true });
			return;
		}

		if (rest === "/notifications/delete") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			// 删除通知记录（移动端通知镜像；不影响 PC 端自己的通知中心）。
			// 仅移除记录本身：后续新事件仍会正常生成新通知（不设墓碑、不静音会话）。
			if (body?.all === true) {
				for (const id of notifStore.keys()) readIds.delete(id);
				notifStore.clear();
			} else if (Array.isArray(body?.ids)) {
				for (const id of body.ids) {
					notifStore.delete(String(id));
					readIds.delete(String(id));
				}
			} else {
				return error(res, 400, "bad-request", "expected { ids } or { all: true }");
			}
			persistReadIds();
			broadcast({ type: "notifications/changed" });
			sendJson(res, 200, { ok: true });
			return;
		}

		if (rest === "/respond") {
			// 移动端回答内核问询/审批：经 apiProxy.respond 走与 PC 端 GUI 完全相同的
			// 校验与结算通道（pending 表、matchesQuestions、approval 决策等由内核把关）。
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			if (!proxy || typeof proxy.respond !== "function") return error(res, 503, "respond-unavailable", "内核 apiProxy 不可用（请升级 dsh）");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			const rpcId = String(body?.rpcId ?? "");
			if (!rpcId) return error(res, 400, "bad-request", "missing rpcId");
			let message;
			if (body?.kind === "question") {
				// answers: [{ id, selected: [label...], custom? }]（顺序与提问一致、每问必答）
				if (!Array.isArray(body?.answers)) return error(res, 400, "bad-request", "question respond expects answers[]");
				message = {
					rpcId,
					result: {
						ok: true,
						value: {
							sessionId: String(body.sessionId ?? ""),
							answer: { answers: body.answers },
						},
					},
				};
			} else if (body?.kind === "approval") {
				// outcome: "allowed-once" | "rejected"
				message = {
					rpcId,
					result: {
						ok: true,
						value: {
							sessionId: String(body.sessionId ?? ""),
							approvalId: String(body.approvalId ?? ""),
							outcome: String(body.outcome ?? ""),
						},
					},
				};
			} else if (body?.kind === "cancel") {
				message = { rpcId, result: { ok: false, error: { code: "cancelled" } } };
			} else {
				return error(res, 400, "bad-request", "kind must be question | approval | cancel");
			}
			try {
				const accepted = await proxy.respond(message);
				sendJson(res, 200, { ok: true, ...(accepted ?? {}) });
			} catch (e) {
				sendJson(res, 200, { ok: true, accepted: false, reason: "error", error: String(e?.message ?? e) });
			}
			return;
		}

		if (rest === "/actions") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			sendJson(res, 200, { ok: true, actions: mobileActions.list() });
			return;
		}

		// ── 余额查询（DeepSeek 官方 /user/balance，key 不经过移动端） ──
		if (rest === "/balance") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const now = Date.now();
			// 缓存兜底：官方 API 慢/抖动（国内常见）时，60 秒内直接返回最近一次成功结果
			if (balanceCache && now - balanceCache.at < 60000) {
				sendJson(res, 200, balanceCache.body);
				return;
			}
			let key;
			try {
				const credentials = ctx.get("credentials");
				if (credentials?.resolve) {
					const resolved = await credentials.resolve(credentialRef("DEEPSEEK_API_KEY"));
					key = resolved?.value;
				}
			} catch {
				// 回退到环境变量
			}
			if (!key) key = process.env.DEEPSEEK_API_KEY;
			if (!key) return error(res, 400, "no-api-key", "未配置 DEEPSEEK_API_KEY（电脑端 设置 → 模型 里填写）");
			try {
				const response = await fetch("https://api.deepseek.com/user/balance", {
					headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
					signal: AbortSignal.timeout(15_000),
				});
				if (!response.ok) {
					if (balanceCache) {
						balanceCache.body.stale = true;
						sendJson(res, 200, balanceCache.body);
						return;
					}
					return error(res, 502, "balance-failed", `DeepSeek API HTTP ${response.status}`);
				}
				const data = await response.json();
				balanceCache = { at: now, body: { ok: true, balance: data } };
				sendJson(res, 200, balanceCache.body);
			} catch (err) {
				if (balanceCache) {
					balanceCache.body.stale = true;
					sendJson(res, 200, balanceCache.body);
					return;
				}
				return error(res, 502, "balance-failed", err.message);
			}
			return;
		}

		// ── 会话 token 统计（聚合 assistant/message 的 usage） ──
		if (rest === "/usage") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const sessionId = url.searchParams.get("sessionId");
			if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
			const sessions = ctx.get("sessions");
			const session = sessions?.get(sessionId);
			if (!session) return error(res, 404, "session-not-found");
			const total = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0, messages: 0 };
			let lastUsage = null; // 最近一次请求的用量样本（圆环同 PC 端口径：只取最新一轮，不用累计总量）
			for (const event of session.events) {
				if (event.type !== "assistant/message" || event.data?.usage === void 0) continue;
				const u = event.data.usage;
				total.inputTokens += u.inputTokens ?? 0;
				total.outputTokens += u.outputTokens ?? 0;
				total.cacheReadTokens += u.cacheReadTokens ?? 0;
				total.cacheWriteTokens += u.cacheWriteTokens ?? 0;
				total.reasoningTokens += u.reasoningTokens ?? 0;
				total.messages += 1;
				lastUsage = u;
			}
			const billed = total.inputTokens + total.cacheReadTokens + total.cacheWriteTokens;
			total.cacheHitRate = billed > 0 ? total.cacheReadTokens / billed : 0;
			// 上下文压力（圆环用）：最近一次请求的 prompt 侧 token，与 PC 端 contextPressure 同口径
			if (lastUsage) {
				total.pressureTokens = (lastUsage.inputTokens ?? 0) + (lastUsage.cacheReadTokens ?? 0) + (lastUsage.cacheWriteTokens ?? 0);
			}
			// 上下文窗口（PC 端圆环同源数据）：优先实时捕获值，回退扫描会话事件
			let contextWindow = contextWindowMap.get(sessionId);
			if (contextWindow === undefined) {
				for (let i = session.events.length - 1; i >= 0; i--) {
					const event = session.events[i];
					if (event.type === "request/context" && Number.isInteger(event.data?.contextWindow)) {
						contextWindow = event.data.contextWindow;
						break;
					}
				}
			}
			sendJson(res, 200, {
				ok: true,
				sessionId,
				usage: total,
				...(contextWindow === undefined ? {} : { contextWindow }),
			});
			return;
		}

		// 修改默认配置（Agent 预设 / 权限预设）——走 /api 桥 settings.update，
		// 与 PC 端设置页同一写入通道；不在 HTTP 回调里直接调 settings 服务（无 fiber 会崩进程）。
		if (rest === "/defaults") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			try {
				if (typeof body.agentPreset === "string" && body.agentPreset !== "") {
					await apiRpc("settings.update", { ns: "agent-presets", patch: { default: body.agentPreset } });
				}
				if (typeof body.permissionPreset === "string" && body.permissionPreset !== "") {
					await apiRpc("settings.update", { ns: "permission", patch: { defaultPreset: body.permissionPreset } });
				}
				sendJson(res, 200, { ok: true });
			} catch (e) {
				error(res, 400, "update-failed", e?.message ?? String(e));
			}
			return;
		}

		// ── 环境诊断（能力探测，让个性化差异可见） ──
		if (rest === "/diagnostics") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			// 服务探测（兼容性诊断）：每个内核服务缺失时的降级行为见 docs/09-compatibility.md
			const probe = (name) => {
				try {
					return ctx.get(name) !== undefined;
				} catch {
					return false;
				}
			};
			const services = {
				webServer: !!(ctx.webServer && typeof ctx.webServer.register === "function"),
				agents: probe("agents"),
				sessions: probe("sessions"),
				llm: probe("llm"),
				permissionPresets: probe("permissionPresets"),
				agentPresets: probe("agentPresets"),
				workspaceRegistry: probe("workspaceRegistry"),
				approval: probe("approval"),
				credentials: probe("credentials"),
				messageFeedback: probe("messageFeedback"),
				userQuestions: probe("userQuestions"),
				apiProxy: !!(proxy && typeof proxy.respond === "function"),
			};
			const checks = { modelsRpc: false, sessionsList: false, directories: false, workspaces: false, notifications: false, actions: false };
			try {
				const agents = ctx.get("agents");
				const sid = agents?.roots()[0]?.id ?? agents?.list()[0]?.id;
				if (sid) {
					const directory = await apiRpc("session.models", { sessionId: sid });
					checks.modelsRpc = Array.isArray(directory?.groups) && directory.groups.length > 0;
				}
			} catch { /* false */ }
			try {
				checks.sessionsList = (ctx.get("sessions")?.list?.().length ?? 0) >= 0;
			} catch { /* false */ }
			try {
				const entries = await readdir(process.cwd(), { withFileTypes: true });
				checks.directories = entries.some((entry) => entry.isDirectory());
			} catch { /* false */ }
			try {
				checks.workspaces = (ctx.get("workspaceRegistry")?.list?.().length ?? 0) > 0;
			} catch { /* false */ }
			checks.notifications = notifStore.size >= 0;
			checks.actions = actionEntries.size >= 0;
			// 问询/审批桥状态（mobile/frame 弹窗链路）：proxy 可用性 + mux 消费循环存活
			checks.respondBridge = !!(proxy && typeof proxy.respond === "function");
			checks.frameBridge = !!(frameAbort && !frameAbort.signal.aborted);
			checks.pendingFrames = pendingFrames.size;
			sendJson(res, 200, {
				ok: true,
				plugin: { name: "dsh-mobile-remote", version: pluginVersion() },
				runtime: {
					form: process.env.DSH_DESKTOP === "1" ? "desktop" : "cli",
					host: ctx.webServer.host,
					port: ctx.webServer.port,
					cwd: process.cwd(),
					authEnabled,
				},
				services,
				checks,
			});
			return;
		}

		// ── 工作区与目录浏览（移动端新建会话选工作目录） ──
		if (rest === "/workspaces") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const registry = ctx.get("workspaceRegistry");
			const workspaces = registry?.list?.() ?? [];
			sendJson(res, 200, {
				ok: true,
				// sessionIds = 内核工作区成员关系（与 PC 端分组一致；会话列表据此过滤）
				workspaces: workspaces.map((w) => ({
					id: w.id,
					path: w.path,
					title: w.title,
					sessionIds: [...(w.sessionIds ?? [])],
				})),
			});
			return;
		}

		if (rest === "/directories") {
			if (method === "POST") {
				// 新建文件夹（移动端目录选择器内创建）
				let body;
				try {
					body = JSON.parse(await readBody(req));
				} catch {
					return error(res, 400, "bad-request");
				}
				const parent = typeof body.path === "string" && body.path !== "" ? body.path : undefined;
				const name = typeof body.name === "string" ? body.name.trim() : "";
				if (name === "" || /[\\/:*?"<>|]/.test(name)) return error(res, 400, "invalid-name", "文件夹名不合法");
				try {
					const target = parent ? join(parent, name) : name;
					mkdirSync(target, { recursive: false });
					sendJson(res, 200, { ok: true, path: target });
				} catch (err) {
					return error(res, 400, "mkdir-failed", err.message);
				}
				return;
			}
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const path = url.searchParams.get("path");
			// 空 path = 根目录视图：Windows 枚举盘符，其他平台返回 /
			if (!path || path === "") {
				let roots = [];
				if (process.platform === "win32") {
					for (let letter = 65; letter <= 90; letter++) {
						const drive = String.fromCharCode(letter) + ":\\";
						if (existsSync(drive)) roots.push(drive);
					}
				} else {
					roots = ["/"];
				}
				sendJson(res, 200, { ok: true, path: "", dirs: roots });
				return;
			}
			const base = path;
			try {
				const entries = await readdir(base, { withFileTypes: true });
				const dirs = entries
					.filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
					.map((entry) => entry.name)
					.sort((a, b) => a.localeCompare(b, "zh-CN"));
				sendJson(res, 200, { ok: true, path: base, dirs });
			} catch (err) {
				return error(res, 400, "directory-unreadable", err.message);
			}
			return;
		}

		const actionMatch = /^\/actions\/([^/]+)\/invoke$/.exec(rest);
		if (actionMatch && method === "POST") {
			const id = decodeURIComponent(actionMatch[1]);
			const entry = actionEntries.get(id);
			if (!entry) return error(res, 404, "action-not-found");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			try {
				await entry.handler(body?.args ?? {});
			} catch (err) {
				return error(res, 500, "action-failed", err.message);
			}
			sendJson(res, 200, { ok: true, accepted: true });
			return;
		}

		// ── v2.7：任务（jobs）/ 子代理 / 目标 ──
		if (rest === "/jobs") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const jobs = ctx.get("jobs");
			if (!jobs) return error(res, 503, "jobs-unavailable");
			const sessionId = url.searchParams.get("sessionId");
			const agents = ctx.get("agents");
			const agent = sessionId && agents ? agents.get(sessionId) : undefined;
			if (sessionId && !agent) return error(res, 404, "session-not-found");
			const views = jobViews(jobs.list(agent ?? undefined));
			sendJson(res, 200, { ok: true, sessionId: sessionId ?? null, jobs: views });
			return;
		}
		if (rest === "/jobs/kill") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			const jobs = ctx.get("jobs");
			if (!jobs) return error(res, 503, "jobs-unavailable");
			const jobId = typeof body.jobId === "string" ? body.jobId : "";
			const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
			if (!jobId) return error(res, 400, "jobId-required");
			const agents = ctx.get("agents");
			const agent = sessionId && agents ? agents.get(sessionId) : undefined;
			try {
				await jobs.kill(jobId, agent ?? undefined, "mobile-remote: user cancelled");
				sendJson(res, 200, { ok: true });
			} catch (err) {
				return error(res, 400, "job-kill-failed", err?.message ?? String(err));
			}
			return;
		}
		if (rest === "/subagents") {
			if (method !== "GET" && method !== "HEAD") return error(res, 405, "method-not-allowed");
			const parentSessionId = url.searchParams.get("parentSessionId");
			if (!parentSessionId) return error(res, 400, "parentSessionId-required");
			const agents = ctx.get("agents");
			const agent = agents?.get(parentSessionId);
			if (!agent) return error(res, 404, "session-not-found");
			try {
				const list = await apiRpc("subagent.list", { parentSessionId });
				const entries = (list?.entries ?? []).map((e) => ({
					id: e.id,
					kind: e.kind ?? "child",
					status: e.kind === "diagnostic" ? e.reason : (e.activity ?? "inactive"),
					title: e.label ?? e.id,
				}));
				sendJson(res, 200, { ok: true, parentAvailable: list?.parentAvailable ?? true, subagents: entries });
			} catch (err) {
				return error(res, err.status ?? 400, "subagent-list-failed", err?.message ?? String(err));
			}
			return;
		}
		if (rest === "/subagents/interrupt") {
			if (method !== "POST") return error(res, 405, "method-not-allowed");
			let body;
			try {
				body = JSON.parse(await readBody(req));
			} catch {
				return error(res, 400, "bad-request");
			}
			const parentSessionId = typeof body.parentSessionId === "string" ? body.parentSessionId : "";
			const childSessionId = typeof body.childSessionId === "string" ? body.childSessionId : "";
			if (!parentSessionId || !childSessionId) return error(res, 400, "parentSessionId-and-childSessionId-required");
			try {
				await apiRpc("subagent.interrupt", { parentSessionId, childSessionId, mode: "continuable" });
				sendJson(res, 200, { ok: true });
			} catch (err) {
				return error(res, err.status ?? 400, "subagent-interrupt-failed", err?.message ?? String(err));
			}
			return;
		}
		if (rest === "/goal") {
			const agents = ctx.get("agents");
			if (method === "GET" || method === "HEAD") {
				const sessionId = url.searchParams.get("sessionId");
				const agent = sessionId && agents ? agents.get(sessionId) : undefined;
				const goals = ctx.get("goals");
				if (!goals || !agent) return error(res, 503, "goal-unavailable");
				try {
					const current = await goals.get(agent);
					sendJson(res, 200, { ok: true, goal: current ?? null });
				} catch (err) {
					return error(res, 400, "goal-get-failed", err?.message ?? String(err));
				}
				return;
			}
			if (method === "POST") {
				let body;
				try {
					body = JSON.parse(await readBody(req));
				} catch {
					return error(res, 400, "bad-request");
				}
				const action = typeof body.action === "string" ? body.action : "";
				const goals = ctx.get("goals");
				const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
				const agent = sessionId && agents ? agents.get(sessionId) : undefined;
				if (!sessionId || !agent) return error(res, 400, "sessionId-required");
				if (!goals) return error(res, 503, "goal-unavailable");
				try {
					// 变更类操作需要当前目标 ref（与 PC 端 goal RPC 契约一致：sessionId + ref）
					const current = await goals.get(agent);
					switch (action) {
						case "create": {
							const objective = typeof body.objective === "string" ? body.objective : "";
							if (!objective) return error(res, 400, "objective-required");
							await apiRpc("goal.create", {
								sessionId,
								objective,
								...(typeof body.maxGoalRounds === "number" ? { maxGoalRounds: body.maxGoalRounds } : {}),
							});
							break;
						}
						case "pause":
						case "resume":
						case "complete": {
							if (!current) return error(res, 400, "no-active-goal");
							await apiRpc(`goal.${action}`, {
								sessionId,
								ref: { id: current.id, revision: current.revision },
							});
							break;
						}
						default:
							return error(res, 400, "bad-action");
					}
					sendJson(res, 200, { ok: true });
				} catch (err) {
					return error(res, err.status ?? 400, "goal-failed", err?.message ?? String(err));
				}
				return;
			}
			return error(res, 405, "method-not-allowed");
		}

		error(res, 404, "not-found");
	};

	// ── 挂载与清理 ──────────────────────────────────────────────
	ctx.effect(() => {
		// 已读集合：文件持久化（不再注册 settings 命名空间）
		loadReadIds();
		// 会话活跃时间 + 归档清单
		loadMetaFiles();
		// ── 问询/审批帧桥：经 ctx.inject 取得 apiProxy（跨插件依赖注入——
		// ctx.get 对兄弟插件注册的服务不可见，这正是 dsh-client-connection
		// 访问 apiProxy 的同款用法），订阅其 mux 队列（PC 端 GUI 同一机制），
		// 只转发 question/approval/session-queue 瞬态帧；应答经 proxy.respond 回写内核。
		try {
			ctx.inject(["apiProxy"], (apiCtx) => {
				if (frameAbort) frameAbort.abort(); // 依赖重新注入时先停旧循环
				const sig = new AbortController();
				frameAbort = sig;
				proxy = apiCtx.apiProxy;
				if (!proxy || typeof proxy.events?.mux !== "function" || typeof proxy.respond !== "function") return;
				(async () => {
					try {
						for await (const envelope of proxy.events.mux({}, sig.signal)) {
							const frame = envelope?.payload;
							if (!frame || typeof frame.type !== "string") continue;
							if (frame.type === "question/requested" || frame.type === "approval/requested") {
								const key = frame.type === "question/requested" ? `q:${envelope.rpcId}` : `a:${frame.approvalId}`;
								pendingFrames.set(key, { ...frame, rpcId: envelope.rpcId });
								broadcast({ type: "mobile/frame", frame: { ...frame, rpcId: envelope.rpcId } });
							} else if (frame.type === "question/resolved") {
								pendingFrames.delete(`q:${frame.questionRpcId}`);
								broadcast({ type: "mobile/frame", frame: { ...frame } });
							} else if (frame.type === "approval/resolved") {
								pendingFrames.delete(`a:${frame.approvalId}`);
								broadcast({ type: "mobile/frame", frame: { ...frame } });
							} else if (frame.type === "session/queue") {
								broadcast({ type: "mobile/frame", frame: { ...frame } });
							}
							// session/event 等其余帧已由 ctx.on("session/event") 桥接，跳过以免重复
						}
					} catch {
						// 队列 dispose / abort：静默退出
					}
				})();
			});
		} catch {
			// 内核过旧无 ctx.inject / apiProxy：桥不可用，/respond 返回 503
		}
		// webServer 守卫：纯 headless 形态（无 web 服务）下插件保持无操作，不崩进程。
		const web = ctx.webServer && typeof ctx.webServer.register === "function" ? ctx.webServer : null;
		const disposers = web ? [
			web.register({
				kind: "prefix",
				path: `${basePath}/api`,
				handler: (req, res) => {
					let url;
					try {
						url = new URL(req.url ?? "/", "http://x");
					} catch {
						return error(res, 400, "bad-request");
					}
					const rest = url.pathname.slice(basePath.length + "/api".length);
					handleApi(req, res, url, rest).catch(() => {
						if (!res.headersSent) error(res, 500, "internal");
						else res.destroy();
					});
				},
			}),
			web.register({
				kind: "exact",
				path: `${basePath}/qr.png`,
				handler: (req, res) => {
					let url;
					try {
						url = new URL(req.url ?? "/", "http://x");
					} catch {
						return error(res, 400, "bad-request");
					}
					serveQr(req, res, url).catch(() => {
						if (!res.headersSent) error(res, 500, "internal");
						else res.destroy();
					});
				},
			}),
		] : [];
		const unsubscribeSession = ctx.on("session/event", onSessionEvent);
		const unsubscribeStatus = ctx.on("agent/status", onAgentStatus);
		// v2.7：任务视图变化 → 重发全部 session/jobs 帧（任务量少，全量最稳）
		const jobsRegistry = ctx.get("jobs");
		const unsubscribeJobsChanged = jobsRegistry?.onJobsChanged?.(() => {
			for (const f of sessionJobsFrames()) broadcast(f);
		});
		const unsubscribeJobDone = jobsRegistry?.onJobDone?.(() => {
			for (const f of sessionJobsFrames()) broadcast(f);
		});
		const heartbeat = setInterval(() => {
			for (const res of [...connections]) {
				try {
					res.write(": ping\n\n");
				} catch {
					dropConn(res); // 心跳写失败 → 僵尸连接立即清理
				}
			}
		}, 25000);
		heartbeat.unref();
		return () => {
			for (const dispose of disposers) dispose();
			unsubscribeSession();
			unsubscribeStatus();
			unsubscribeJobsChanged?.();
			unsubscribeJobDone?.();
			if (frameAbort) frameAbort.abort();
			proxy = null;
			frameAbort = null;
			pendingFrames.clear();
			clearInterval(heartbeat);
			for (const res of connections) res.destroy();
			connections.clear();
		};
	}, "mobile-remote: /m routes and event bridge");
}
