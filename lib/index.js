/**
 * dsh-mobile-remote — 手机远程操作 dsh agent 的 host 插件。
 *
 * 在 web profile 的 webserver 上注册 /m 前缀路由，提供移动端 API 与 SSE 事件桥：
 * 发消息（agent.followup / steer）、看进度与收通知（session/event + agent/status
 * 事件桥 → SSE）、会话历史、二维码、充值入口。
 *
 * 设计依据见 docs/01-PRD.md ~ docs/04-security.md。
 */
import { networkInterfaces, homedir } from "node:os";
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { createServer as createHttpServer, request as httpRequest } from "node:http";
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
	 * 真结束判定宽限（毫秒，v2.8.0）：agent 转为 idle 后需稳定此时长、
	 * 且无 active goal，才判定"对话真正结束"并通知——多轮大任务不再
	 * 每完成一个子轮次就推一次"任务完成"。
	 */
	doneGraceMs: z.number().default(15_000),
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
	/**
	 * LAN 桥（v2.9.0）：桌面版（dsh-plugin-desktop）强制 webserver 只听回环，手机无法直连；
	 * 插件在 DSH 进程内自建第二个 HTTP 监听，把 `${path}` 前缀请求流式转发到回环 webserver。
	 * 仅暴露移动端面（不转发 /api 网关、qr-config/qr.png）；未配置 authToken 时拒绝启动。
	 * 默认关闭；启用后手机访问 `http://<电脑局域网IP>:<port>/m`（App 扫码/手动填均可）。
	 */
	lanBridge: z
		.object({
			enabled: z.boolean().default(false),
			// v2.9.0 review(M#7)：port 合法区间 1-65535（0=随机端口会与上报地址错位），host 非空
			port: z.number().min(1).max(65535).default(3080),
			host: z.string().min(1).default("0.0.0.0"),
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

/** ContentBlock[] → 图片元数据（仅引用不含字节；渲染时 App 按 attachmentId 走 /attachment 端点拉取）。 */
function imagesOf(blocks) {
	const out = [];
	for (const block of blocks ?? []) {
		const ref = block?.type === "image" ? block.attachment : undefined;
		if (!ref || typeof ref !== "object" || !ref.attachmentId) continue;
		out.push({
			attachmentId: String(ref.attachmentId),
			mediaType: typeof ref.mediaType === "string" ? ref.mediaType : "image/jpeg",
			...(Number.isFinite(ref.width) ? { width: ref.width } : {}),
			...(Number.isFinite(ref.height) ? { height: ref.height } : {}),
			...(typeof ref.name === "string" && ref.name !== "" ? { name: ref.name } : {}),
		});
	}
	return out;
}

/**
 * 把 SessionEvent 裁剪成移动端摘要（docs/03-api.md §3.7）。
 * 返回 { seq, type, data? }；未识别类型仅保留 type，客户端忽略。
 */
export function summarizeEvent(event) {
	const { seq, type, data } = event;
	// review：内核实参可能缺 data（防御，避免 TypeError 打崩事件发射器）
	if (data === undefined) return { seq, type };
	switch (type) {
		case "user/message": {
			const message = data;
			const images = imagesOf(message.content);
			return {
				seq,
				type,
				data: {
					messageId: message.id,
					text: clampText(blocksToText(message.content), 2000),
					...(images.length ? { images } : {}),
				},
			};
		}
		case "assistant/message": {
			const message = data.message;
			// review：深层字段缺失守卫（message 缺失时返回空摘要而非 TypeError）
			if (!message || typeof message !== "object") return { seq, type };
			const images = imagesOf(message.content);
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
					...(images.length ? { images } : {}),
					...(data.usage === void 0 ? {} : { usage: data.usage }),
				},
			};
		}
		case "assistant/chunk": {
			const chunk = data.chunk;
			if (!chunk || typeof chunk !== "object") return { seq, type };
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
	// ── LAN 桥（v2.9.0）配置归一（apply 作用域：bootstrap/qr-config/diagnostics 也要读） ──
	const lanEnabled = Boolean(config.lanBridge?.enabled);
	const lanPort = config.lanBridge?.port ?? 3080;
	const lanHost = config.lanBridge?.host ?? "0.0.0.0";
	let lanServer = null;
	// 实际监听成功才算可用（绑定失败时 QR/地址回退回环，不指向死端口）
	let lanBridgeListening = false;
	// 在网桥连接集（卸载时全部销毁，不留半开）
	const lanBridgeSockets = new Set();
	if (!authEnabled) {
		ctx.logger.warn(
			"mobile-remote: 访问口令（authToken）未启用——同一网络内任何设备都能连接并控制 agent，建议立即配置强口令（见 docs/04-security.md）"
		);
	} else if (config.authToken.length < 16) {
		// v2.9.0 review(B6)：弱口令告警(仅警告不阻断，避免既有用户升级即断)
		ctx.logger.warn("mobile-remote: authToken 短于 16 字符，建议更换为 ≥16 字符强随机口令");
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

	// ── 移动端「排队」持存区（v3.0.0 review 落实 · 方案 A）──────────────────
	// 语义：运行中由移动端 followup 发送的消息**不交给内核 next-turn**（内核会在当前轮结束的
	// 瞬间自动认领执行——PC 端同款语义，用户在移动端不想要），而是先在插件侧暂存：
	// + agent 真正空闲（整个任务/目标结束）后按序自动释放（followup → 新轮次执行）；
	// + dock 行操作全部在插件侧完成：删除/编辑永远成功（无"已被认领"竞态）；插队=立即 steer
	//   注入当前运行（下一步边界执行，与 PC 端插队一致）。
	// 持久化到文件（与 read-notifs 同目录），插件重启不丢暂存消息。
	const HELD_FILE = join(homedir(), ".dsh", "mobile-remote", "held-queue.json");
	const heldQueue = new Map(); // sessionId -> [{ id, text, images?, at }]
	const heldOf = (sessionId) => heldQueue.get(sessionId) ?? [];
	const persistHeld = () => {
		try {
			mkdirSync(join(homedir(), ".dsh", "mobile-remote"), { recursive: true });
			const tmp = HELD_FILE + ".tmp";
			writeFileSync(tmp, JSON.stringify({ held: Object.fromEntries(heldQueue) }), "utf8");
			renameSync(tmp, HELD_FILE);
		} catch {
			// 写入失败仅影响暂存持久化
		}
	};
	const loadHeld = () => {
		try {
			const doc = JSON.parse(readFileSync(HELD_FILE, "utf8"));
			const held = doc?.held;
			if (held && typeof held === "object") {
				for (const [sid, list] of Object.entries(held)) {
					if (Array.isArray(list)) {
						heldQueue.set(sid, list
							// v3.0.0 图像链路：图片条目允许 text 为空（图像独占）；仅保留有内容(文本或图)的条目
							.filter((m) => typeof m?.id === "string" && m.id !== "" && (typeof m?.text === "string" || Array.isArray(m?.images) && m.images.length > 0))
							.map((m) => ({
								id: m.id,
								text: typeof m.text === "string" ? m.text : "",
								...(Array.isArray(m.images) && m.images.length > 0
									? { images: m.images.filter((im) => im && typeof im?.data === "string" && typeof im?.mediaType === "string") }
									: {}),
								at: Number(m.at) || 0,
							})));
					}
				}
			}
		} catch {
			// 文件不存在或损坏：保持内存态
		}
	};
	/** 会话队列统一视图：内核 inbox 行 + 插件持存行（持存排最后=发送时序）。 */
	const queueRowsOf = (sessionId) => {
		const agents = ctx.get("agents");
		const agent = agents?.get(sessionId);
		const rows = [];
		if (agent?.inbox) {
			for (const msg of agent.inbox.nextTurn ?? []) rows.push({ id: msg.id, text: messageTextOf(msg), placement: "queued" });
			for (const msg of (agent.inbox.nextStep ?? []).filter((m) => m?.source?.kind !== "user")) rows.push({ id: msg.id, text: messageTextOf(msg), placement: "context" });
			for (const msg of (agent.inbox.nextStep ?? []).filter((m) => m?.source?.kind === "user")) rows.push({ id: msg.id, text: messageTextOf(msg), placement: "steering" });
		}
		for (const held of heldOf(sessionId)) {
			rows.push({
				id: held.id,
				// v3.0.0 图像链路：图片独占行预览「[图片] ×N」；文本+图则「文本 [图片] ×N」
				text: held.text && held.images?.length
					? `${held.text} [图片] ×${held.images.length}`
					: held.images?.length
						? `[图片] ×${held.images.length}`
						: held.text,
				placement: "queued",
			});
		}
		return rows;
	};
	const broadcastQueue = (sessionId) => {
		if (typeof sessionId !== "string" || sessionId === "") return;
		broadcast({ type: "mobile/queue", sessionId, rows: queueRowsOf(sessionId) });
	};
	/** 持存条目 → 内核 prompt content（文本+图 wire，与 PC 端同形状）。 */
	const heldContentOf = (h) => {
		const parts = [];
		if (h.text !== "") parts.push({ type: "text", text: h.text });
		for (const im of h.images ?? []) parts.push({ type: "image", mediaType: im.mediaType, data: im.data, ...(typeof im.name === "string" && im.name !== "" ? { name: im.name } : {}) });
		return parts;
	};
	/** 图片消息经内核 session.prompt 发送（与 PC 端同 wire；限额/降采样由内核负责）。 */
	const promptImage = (sessionId, mode, content) => apiRpc("session.prompt", { sessionId, mode, content }, 120_000);
	/** agent 空闲 → 释放全部持存消息（按发出时序 followup，新轮次执行；图片走 prompt）。 */
	const releaseHeld = (sessionId) => {
		const held = heldOf(sessionId);
		if (held.length === 0) return;
		const agents = ctx.get("agents");
		const agent = agents?.get(sessionId);
		if (!agent) return; // 会话不在内存：保留待下次
		heldQueue.set(sessionId, []);
		persistHeld();
		for (const h of held) {
			if (h.images?.length) {
				promptImage(agent.id, "queue", heldContentOf(h)).catch((err) => {
					ctx.logger.warn(`mobile-remote: 释放图片消息失败(${sessionId}): ${err?.message ?? err}`);
				});
			} else {
				const message = createUserMessage({ content: [{ type: "text", text: h.text }], source: { kind: "user" } });
				agent.followup(message);
			}
		}
		broadcastQueue(sessionId);
		ctx.logger.info?.(`mobile-remote: 任务结束，释放 ${held.length} 条排队消息（${sessionId}）`);
	};
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
	// v2.9.0 review(M#8)：已读/删除标记去抖落盘（500ms 合并批量操作，避免每次请求同步全量写盘阻塞事件循环）
	let readPersistTimer = null;
	const scheduleReadPersist = () => {
		if (readPersistTimer) return;
		readPersistTimer = setTimeout(() => {
			readPersistTimer = null;
			persistReadIds();
		}, 500);
		readPersistTimer.unref?.();
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
		// v2.7.2 review(S1)：session 可能为 undefined（会话刚销毁/不在 sessions 注册表），
		// 空守卫避免 TypeError 打崩审批帧桥/通知路径
		for (let i = (session?.events?.length ?? 0) - 1; i >= 0; i--) {
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
		const title = notifyTitle(sessionId, session);
		const now = Date.now();
		// v2.7.2：通知改由"真结束"判定驱动（见 armDone），每条通知独立成条、
		// 互不合并、不覆盖已读；id 带随机后缀防同毫秒碰撞（review）
		const id = `${sessionId}:${kind}:${now}:${Math.random().toString(36).slice(2, 8)}`;
		notifStore.set(id, { id, kind, sessionId, title, detail, time: now });
		if (notifStore.size > NOTIF_MAX) {
			const oldest = [...notifStore.keys()].sort((a, b) => notifStore.get(a).time - notifStore.get(b).time)[0];
			notifStore.delete(oldest);
			// v2.7.2 review(M4)：逐出通知时同步清理已读集合，避免 readIds 无界膨胀
			readIds.delete(oldest);
		}
		// 通知变化即时广播：移动端铃铛角标/通知页实时刷新（v2.7 修复：之前仅重连/下拉才拉取）
		broadcast({ type: "notifications/changed" });
		// v2.7.2：通知帧直推 SSE——悬浮球/App 渲染与通知中心同源（悬浮球不再自行按轮次弹）
		broadcast({ type: "mobile/notify", notification: { id, kind, sessionId, title, detail, time: now } });
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
		const shortId = shortSessionId(sessionId);
		const redactedTitle = pushMinimal ? shortId : title;
		const redactedDetail = pushMinimal ? "" : detail;
		for (const target of config.pushUrls) {
			await pushToChannel(target, kind, kindLabel, redactedTitle, redactedDetail, sessionId).catch((err) => {
				ctx.logger.warn(`mobile-remote: push to "${target.name}" failed: ${err?.message ?? err}`);
			});
		}
	};
	// ── 真结束通知（v2.7.2）──────────────────────────────
	// 多轮大任务（goal 驱动/连续队列）每轮 turn/end 只暂存结果；agent 转 idle
	// 且稳定 doneGraceMs、无 active goal，才判定"对话真正结束"→ 通知一次。
	const pendingOutcomes = new Map(); // sessionId -> { kind, detail }
	const doneTimers = new Map(); // sessionId -> Timeout
	// review M2：needs-answer 时间窗去重——同一会话 10 秒内只发一条。
	// 场景：审批/提问帧桥（approval/question requested）与对应轮次 turn/end blocked
	// 走两条通道都会触发 needs-answer，避免通知中心出现同事件两条。
	const lastNeedsAnswerAt = new Map(); // sessionId -> last notify time
	const NEEDS_ANSWER_DEDUP_MS = 10_000;
	const notifyNeedsAnswer = (sessionId, detail) => {
		const now = Date.now();
		const last = lastNeedsAnswerAt.get(sessionId) ?? 0;
		if (now - last < NEEDS_ANSWER_DEDUP_MS) return false; // 已发过，跳过
		lastNeedsAnswerAt.set(sessionId, now);
		pushNotification(sessionId, "needs-answer", detail);
		const sessions = ctx.get("sessions");
		const sess = sessions?.get(sessionId);
		pushSend("needs-answer", sessionId, notifyTitle(sessionId, sess), detail).catch(() => {}); // review：浮动 promise 兜底
		return true;
	};
	const pendingEpochs = new Map(); // sessionId -> 自增序号（review M1：取消/重 arm 后旧回调失效）
	const bumpEpoch = (sessionId) => {
		pendingEpochs.set(sessionId, (pendingEpochs.get(sessionId) ?? 0) + 1);
	};
	const cancelDone = (sessionId) => {
		const t = doneTimers.get(sessionId);
		if (t) clearTimeout(t);
		doneTimers.delete(sessionId);
		pendingOutcomes.delete(sessionId);
		bumpEpoch(sessionId); // 使已排队的回调在 await 之后也判定失效
	};
	const armDone = (sessionId, kind, detail) => {
		const epoch = (pendingEpochs.get(sessionId) ?? 0) + 1;
		pendingEpochs.set(sessionId, epoch);
		pendingOutcomes.set(sessionId, { kind, detail });
		const old = doneTimers.get(sessionId);
		if (old) clearTimeout(old);
		const handle = setTimeout(async () => {
			try {
				doneTimers.delete(sessionId);
				const pending = pendingOutcomes.get(sessionId);
				if (!pending) return;
				// review M1：期间被 cancel/重新 arm（新轮次开始）→ 放弃本次判定
				if (pendingEpochs.get(sessionId) !== epoch) return;
				const agents = ctx.get("agents");
				const agent = agents?.get(sessionId);
				// 又跑起来了（新轮次已开始）→ 放弃本次判定
				if (agent && agent.status !== "idle") {
					pendingOutcomes.delete(sessionId);
					return;
				}
				// 会话仍有 active goal → 大任务还在进行，继续等（到期复查）
				const goals = ctx.get("goals");
				if (goals && agent) {
					try {
						const goal = await goals.get(agent);
						// review M1：await 期间可能 turn/start → cancelDone → epoch 变化，必须复查
						if (pendingEpochs.get(sessionId) !== epoch) return;
						if (goal && goal.phase === "active") {
							// 用当前 pending（而非闭包参数）重 arm，避免旧轮次详情覆盖新值
							armDone(sessionId, pending.kind, pending.detail);
							return;
						}
					} catch {
						// 查询失败不阻塞通知
					}
				}
				// 通知前最后校验一次
				if (pendingEpochs.get(sessionId) !== epoch) return;
				pendingOutcomes.delete(sessionId);
				const sessions = ctx.get("sessions");
				const session = sessions?.get(sessionId);
				pushNotification(sessionId, pending.kind, pending.detail);
				pushSend(pending.kind, sessionId, notifyTitle(sessionId, session), pending.detail).catch(() => {}); // review：浮动 promise 兜底
			} catch (err) {
				// v2.7.2 加固：定时器回调任何异常都不许外泄（async rejection 默认会让 Node 崩进程）
				ctx.logger.warn(`mobile-remote: done-timer failed for ${sessionId}: ${err?.message ?? err}`);
			}
		}, config.doneGraceMs);
		handle.unref?.();
		doneTimers.set(sessionId, handle);
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
	 *  = 回环（含 IPv6 ::1）+ 本机全部 internal IPv4（含 Tailscale/ZeroTier/WireGuard 虚拟网段）+ 显式配置的 `trustedHosts`（内网穿透中转）。 */
	const trustedHosts = () => new Set([
		"127.0.0.1", "localhost", "::1",
		...ipv4Addresses(),
		// v2.7.2 review：配置统一小写，避免大小写失配
		...config.trustedHosts.map((h) => String(h).toLowerCase()),
	]);

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
		let hostname;
		if (host.startsWith("[")) {
			// IPv6 字面量 [::1]:3080
			const end = host.indexOf("]");
			hostname = end === -1 ? host : host.slice(1, end);
		} else {
			hostname = host.split(":")[0];
		}
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
		// v2.7.2 review(M6)：封锁时长按 blockMs 判定（此前被 windowMs 覆盖，blockMs 形同虚设）
		return b !== undefined && now - b.windowStart < rateLimitCfg.blockMs && b.count >= rateLimitCfg.maxFailures;
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
		// v2.7.2 review(S2)：客户端中途断开后对已销毁响应 writeHead/end 会 emit 'error'，
		// 无监听时 Node 抛未捕获异常 → 崩进程；挂一次性 noop 监听兜底
		guardRes(res);
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
					// v3.0.0 修复：超限先停读并让 handler 回 413——此前先 req.destroy()
					// 会把连接直接掐断,客户端看到的是"连接意外关闭/连接重置"而非 413
					// (592KB 图片上传即此症状:上游看到连接被切断 → 桥回 502 bridge-unavailable)
					req.pause();
					return;
				}
				chunks.push(chunk);
			});
			req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
			req.on("error", reject);
			// review：客户端断开且不触发 error 时也要 settle，避免 handler 悬挂
			req.on("close", () => reject(Object.assign(new Error("request closed"), { status: 400 })));
		});
	// v2.7.2 review(M7)：请求体解析失败统一处理——超限透传 413，其余 400
	const bodyError = (err, res) => error(res, err?.status === 413 ? 413 : 400, err?.status === 413 ? "payload-too-large" : "bad-request");
	// Phase 1(S1)：读请求体并解析 JSON；失败已响应（bodyError），返回 undefined 供调用点提前 return。
	// v3.0.1：接受可选 limit 参数并透传 readBody——/send（图片 base64 大 body）传入 64MB，
	// 其余端点保持默认 64KB。此前该参数被静默丢弃，图片 >64KB 即触发 req.destroy()，
	// 手机端表现为 "Connection reset by peer"/桥 502 "upstream webserver unreachable"。
	const readJson = async (req, res, limit) => {
		try {
			return JSON.parse(await readBody(req, limit));
		} catch (err) {
			return bodyError(err, res);
		}
	};
	// Phase 1(S6)：方法检查收敛——不匹配时已响应 405 并返回 true，调用点 `if (requireGet(method, res)) return;`
	const requireGet = (method, res) => {
		if (method !== "GET" && method !== "HEAD") {
			error(res, 405, "method-not-allowed");
			return true;
		}
		return false;
	};
	const requirePost = (method, res) => {
		if (method !== "POST") {
			error(res, 405, "method-not-allowed");
			return true;
		}
		return false;
	};

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
				// v2.7.2 review(M5)：SSE 背压保护——慢客户端（弱网/后台）socket 缓冲满时
				// 帧会无限堆积内存；未确认字节超阈值直接踢掉（客户端会自动重连 + /history 补漏）
				if (typeof res.writableLength === "number" && res.writableLength > 256 * 1024) {
					ctx.logger.warn("mobile-remote: dropping slow SSE client (backpressure)");
					dropConn(res);
				}
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
	const pendingFrames = new Map(); // `q:${rpcId}` / `a:${approvalId}` -> { rpcId, at, ...frame }
	// v2.7.2 review(M3)：上限 + TTL，防"永不回答的审批/提问帧"永久残留并在每次重连全量回放
	const PENDING_FRAMES_MAX = 200;
	const PENDING_FRAMES_TTL = 24 * 3600 * 1000;
	const pendingFrameSet = (key, frame) => {
		// review：先删再设，刷新插入序（超限逐出时不会误逐刚更新的帧）
		pendingFrames.delete(key);
		pendingFrames.set(key, { ...frame, at: Date.now() });
		if (pendingFrames.size > PENDING_FRAMES_MAX) {
			// Map 按插入序迭代：超限逐出最旧
			const oldest = pendingFrames.keys().next().value;
			pendingFrames.delete(oldest);
		}
	};
	let frameAbort = null; // 卸载时终止 mux 消费循环

	const connect = (res) => {
		if (connections.size >= config.maxConnections) {
			res.writeHead(503, { "content-type": "application/json; charset=utf-8" });
			res.end(JSON.stringify({ error: "too-many-connections" }));
			return;
		}
		// review：先挂清理监听再写头/回放——握手瞬间客户端断开时不会留下滞留连接
		//（此前 close/error 监听在写完后才挂,握手即断的死连接靠 25s 心跳兜底）
		res.on("close", () => connections.delete(res));
		// 半开连接：客户端进程被杀/断网后 close 可能迟迟不来，error 事件立即清理僵尸
		res.on("error", () => connections.delete(res));
		res.writeHead(200, {
			"content-type": "text/event-stream",
			"cache-control": "no-cache",
			"connection": "keep-alive",
		});
		res.write(": connected\n\n");
		res.write(`data: ${JSON.stringify({ type: "hello", serverTime: Date.now() })}\n\n`);
		connections.add(res);
		// 补发断线期间挂起的问询/审批（与 PC 端 GUI 连接时的 pending 回放一致；超 TTL 的僵尸帧先清掉）
		for (const [key, f] of pendingFrames) {
			if (Date.now() - (f.at ?? 0) > PENDING_FRAMES_TTL) {
				pendingFrames.delete(key);
				continue;
			}
			res.write(`data: ${JSON.stringify({ type: "mobile/frame", frame: f })}\n\n`);
		}
		// v2.7：连接回放各会话任务视图（与 PC 端 GUI 同源）
		for (const f of sessionJobsFrames()) {
			res.write(`data: ${JSON.stringify(f)}\n\n`);
		}
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
		// 通知聚合（v2.7.2）：
		// - needs-answer（blocked）→ 立即通知（交互式提问不能等）
		// - completed / failed → 先暂存，等"真结束"（agent idle + 宽限 + 无 active goal）再通知；
		//   真·子代理会话（header.origin === "subagent"，DSH 0.1.1-rc.2 内核标记）是父任务的
		//   一部分，一律不通知完成/失败；**fork 出的独立会话（仅 parentSession、无 origin）
		//   是用户自己的平行对话，照常通知**（v3.0.1 修正：此前按 parentSession 判定把 fork 也抑制了）
		if (event.type === "turn/end") {
			const reason = event.data?.reason;
			const kind = reason?.kind;
			const turn = event.data?.turn;
			let notifKind;
			let detail;
			if (kind === "completed" || kind === "max-tokens") {
				notifKind = "completed";
				detail = kind === "max-tokens"
					? `任务完成（轮次 ${turn}，max-tokens 截断）`
					: `任务完成（轮次 ${turn}）`;
			} else if (kind === "error" || kind === "interrupted" || kind === "aborted") {
				notifKind = "failed";
				detail = kind === "error" && typeof reason?.error?.message === "string"
					? `任务失败：${reason.error.message.slice(0, 120)}`
					: `任务${kind === "aborted" ? "已取消" : "失败"}（轮次 ${turn}）`;
			} else if (kind === "blocked") {
				notifKind = "needs-answer";
				detail = "agent 正在等待你的回答";
			}
			if (notifKind) {
				if (notifKind === "needs-answer") {
					// review M2：与审批/提问帧桥共用时间窗去重，同一事件不双发
					notifyNeedsAnswer(session.id, detail);
					// 等回答期间不应再发"完成/失败"：清掉该会话待定结果
					cancelDone(session.id);
				} else if (session.header?.origin === "subagent") {
					// 真·子代理会话：不通知（它是父任务的一部分，父任务结束才通知）；
					// fork 会话无 origin 标记 → 走正常通知（v3.0.1 修正）
					cancelDone(session.id);
				} else {
					armDone(session.id, notifKind, detail);
				}
			}
		} else if (event.type === "turn/start") {
			// 新一轮开始 = 上一轮结果作废（宽限判定一并取消）
			cancelDone(session.id);
		}
	};
	const onAgentStatus = (payload) => {
		// v2.7.2：帧补 sessionId（去 "session:" 前缀）与 child 标志，供悬浮球渲染/过滤
		const agentSession = payload.agent?.session;
		const sessionId = agentSessionId(payload.agent);
		broadcast({
			type: "agent/status",
			sessionId,
			agentId: payload.agent?.id ?? "", // review：payload.agent 可能缺失（防御）
			status: payload.status,
			// v3.0.1：child 判定对齐内核——仅 origin === "subagent" 是真子代理
			// （fork 出的独立会话也有 parentSession 但无 origin，应为正常主会话处理）
			child: agentSession?.header?.origin === "subagent",
		});
		// 恢复运行 = 宽限判定作废（防御：正常情况下 turn/start 已处理）
		if (payload.status === "running" && sessionId) cancelDone(sessionId);
		// v3.0.0（方案 A）：agent 真正空闲（整个任务/目标结束）→ 释放持存的排队消息
		if (payload.status === "idle" && sessionId) releaseHeld(sessionId);
	};

	// ── HTTP 处理器 ─────────────────────────────────────────────
	const serveQr = async (req, res, url) => {
		if (requireGet(req.method, res)) return;
		// v2.6.0：与 qr-config 同策略——仅电脑本机可访问（桌面设置页本就要求 loopback 才能拉到数据）
		if (!hostAllowed(req)) {
			error(res, 403, "host-not-allowed");
			return;
		}
		const remote = String(req.socket.remoteAddress ?? "");
		const loopback = isLoopback(remote);
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
			// v2.7.2 review：serveQr 直写路径也挂 error noop（异步生成期间客户端断开 →
			// 对已销毁响应 writeHead/end emit 'error' 无监听会崩进程，与 sendJson 同款守卫）
			guardRes(res);
			const buffer = await QRCode.toBuffer(text, { width: 512, margin: 1, errorCorrectionLevel: "M" });
			res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
			res.end(buffer);
		} catch {
			error(res, 400, "bad-request", "qr encode failed");
		}
	};

	// ── 移动端 v2 公共 helper ─────────────────────────────────────
	/** 通过 /api 桥调用 PC 端 Remote（与浏览器 GUI 同一 HTTP 协议，loopback 在信任围栏内）。 */
	const apiRpc = async (method, payload, timeoutMs = 15000) => {
		const port = ctx.webServer.port;
		const response = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ type: "client-request", rpcId: randomUUID(), method, payload }),
			signal: AbortSignal.timeout(timeoutMs),
		});
		if (!response.ok) throw Object.assign(new Error(`rpc transport failed: HTTP ${response.status}`), { status: 502 });
		const full = await response.json();
		if (!full?.result?.ok) {
			// v2.7.2：错误带上内核 code（如 queue-item-not-found / steer-unavailable），供客户端区分处理
			const e = new Error(full?.result?.error?.message ?? `${method} failed`);
			e.status = 400;
			e.code = full?.result?.error?.code;
			throw e;
		}
		return full.result.value;
	};
	// Phase 1(S3)：apiRpc 失败统一映射——传输层 502、超时/中止 504、内核错误透传 status（默认 400），
	// 错误码兜底 fallbackCode。返回 [status, code, message] 元组，展开进 error()：
	//   error(res, ...rpcError(err, "xxx-failed")) → { error: code, detail: message }
	// v2.8.2 修复：调用展开 f(...obj) 走迭代器协议，要求 obj 为 iterable——普通对象字面量与
	// Object.create(null) 均非 iterable，会抛 "Spread syntax requires ...iterable[Symbol.iterator]"：
	// 2.8.1 起全部 11 处 API 错误路径因此退化为 HTTP 500 { error: "internal" }，真实 status/code/detail
	// 全部丢失（该 TypeError 上抛到 handleApi 外层 catch）。数组是唯一同时满足展开与三元组表达的形态。
	// code 仅接受非空 string：内核自定义错误码是文档字符串（queue-item-not-found 等），
	// DOMException.code 等数字码不在契约内 → 落 fallbackCode（行为收窄，见 docs 契约）。
	const rpcError = (err, fallbackCode) => {
		const status = err?.status === 502
			? 502
			: err?.name === "TimeoutError" || err?.name === "AbortError"
				? 504
				: err?.status ?? 400;
		const code = typeof err?.code === "string" && err.code !== "" ? err.code : fallbackCode;
		let message;
		try {
			message = err?.message ?? String(err);
		} catch {
			message = String(fallbackCode);
		}
		return [status, code, message];
	};
	/** 用户消息 content blocks → 预览文本（队列视图显示用；对齐 PC 端 previewOf 语义）。 */
	const messageTextOf = (msg) => {
		const blocks = msg?.content;
		if (!Array.isArray(blocks)) return "";
		return blocks
			.map((b) => (b && typeof b === "object" && b.type === "text" && typeof b.text === "string" ? b.text : ""))
			.filter((t) => t !== "")
			.join(" ")
			.replace(/\s+/g, " ")
			.trim()
			.slice(0, 200);
	};
	// ── Phase 0 收敛 helper（统一散落各处的重复写法） ──
	/** 会话/agent id 归一（去 "session:" 前缀）。 */
	const agentSessionId = (agent) => agent?.session?.id ?? String(agent?.id ?? "").replace(/^session:/, "");
	/** 回环地址判定。 */
	const isLoopback = (remote) => remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
	/** 首个 root agent（无 root 时退回任意 agent）。 */
	const firstAgent = (agents) => agents?.roots()[0] ?? agents?.list()[0];
	/** 会话短码（统一格式：前 8 + … + 后 4；短 id 原样）。 */
	const shortSessionId = (id) => (id.length > 12 ? `${id.slice(0, 8)}…${id.slice(-4)}` : id);
	/** 通知标题：会话标题兜底短码。 */
	const notifyTitle = (sessionId, session) => sessionTitleOf(session) ?? shortSessionId(sessionId);
	/** 响应防崩守卫（写已销毁响应时 error 事件有监听）。 */
	const guardRes = (res) => {
		if (!res.__dshErrGuarded) {
			res.__dshErrGuarded = true;
			res.on("error", () => {});
		}
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
			if (requireGet(method, res)) return;
			const agents = ctx.get("agents");
			const sessions = ctx.get("sessions");
			const agentList = agents
				? agents.list().map((agent) => ({ id: agent.id, status: agent.status, hasPending: agent.inbox?.hasPending ?? false }))
				: [];
			const sessionList = sessions
				? sessions.list().map((session) => ({ id: session.id, createdAt: session.header.createdAt, cwd: session.header.cwd }))
				: [];
			// v2.9.0：LAN 桥**实际监听成功**时首选地址 = 桥地址（手机可达），回环地址仅本机自连兜底；
			// 绑定失败（EADDRINUSE/端口非法）→ 回退 webserver 地址，扫码不指向死端口
			const urls = lanBridgeListening
				? [...privateFirst(ipv4Addresses()).map((ip) => `http://${ip}:${lanPort}`), `http://127.0.0.1:${ctx.webServer.port}`]
				: [...privateFirst(ipv4Addresses()), "127.0.0.1"].map((ip) => `http://${ip}:${ctx.webServer.port}`);
			sendJson(res, 200, {
				ok: true,
				auth: { enabled: authEnabled },
				server: { port: ctx.webServer.port, urls, path: basePath },
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
			if (requireGet(method, res)) return;
			const remote = String(req.socket.remoteAddress ?? "");
			const loopback = isLoopback(remote);
			if (!loopback) return error(res, 403, "loopback-only", "仅电脑本机可访问");
			// v2.9.0：LAN 桥实际监听成功 → 二维码首要地址 = 桥地址（手机扫码直连；本机回环地址对
			// 手机不可达，不再展示）；绑定失败 → 回退 webserver 地址（不会指向死端口）
			const qrUrls = lanBridgeListening
				? [...privateFirst(ipv4Addresses())].map((ip) => `http://${ip}:${lanPort}${basePath}`)
				: [...privateFirst(ipv4Addresses()), "127.0.0.1"].map((ip) => `http://${ip}:${ctx.webServer.port}${basePath}`);
			sendJson(res, 200, {
				ok: true,
				urls: qrUrls,
				token: config.authToken,
				path: basePath,
			});
			return;
		}

		if (rest === "/send") {
			if (requirePost(method, res)) return;
			// v3.0.0（图像链路）：图片走 base64 wire（与 PC 端同款），请求体上限放宽到 64MB（默认 64KB）。
			// v3.0.1：声明式 content-length 预检——超限直接回 413 JSON（桥可透传），避免 readBody
			// 中途 destroy 导致客户端只看到 RST/502 而拿不到原因；无 content-length 时仍由 readBody 兜底。
			const declaredLength = Number(req.headers["content-length"]);
			if (Number.isFinite(declaredLength) && declaredLength > 64 * 1024 * 1024) {
				return error(res, 413, "payload-too-large", "request body exceeds 64MB limit");
			}
			const body = await readJson(req, res, 64 * 1024 * 1024);
			if (body === undefined) return;
			const text = typeof body?.text === "string" ? body.text : "";
			// v3.0.0：图片附件 [{ mediaType, data(base64), name? }]——PC 端 wire 同形状
			const images = Array.isArray(body?.images)
				? body.images.slice(0, 20)
					.filter((im) => im && typeof im?.data === "string" && im.data !== "" && typeof im?.mediaType === "string")
				: [];
			if (text.trim() === "" && images.length === 0) return error(res, 400, "empty-text");
			// v2.7.2：mode=steer 插队发送（插到 agent 下一步执行，team/子会话向主会话插队场景）；
			// 默认 followup 排队。agent 空闲时插队无意义 → 降级排队并在响应中标注。
			// v3.0.0（方案 A）：**运行中**的 followup 不再交给内核 next-turn（内核会在当前轮结束
			// 瞬间自动认领执行，移动端用户不想要）——改为插件侧持存：dock 行可删除/编辑/插队，
			// agent 真正空闲（整个任务结束）后按序自动释放。空闲/无 agent 时仍走内核 followup。
			const steer = body?.mode === "steer";
			const agents = ctx.get("agents");
			if (!agents) return error(res, 503, "agents-unavailable");
			const sessionId = typeof body?.sessionId === "string" && body.sessionId ? body.sessionId : undefined;
			const target = sessionId ? agents.get(sessionId) : agents.roots()[0];
			if (!target) return error(res, sessionId ? 404 : 503, sessionId ? "session-not-found" : "no-live-agent");
			// v3.0.0 图像链路：与 PC 端完全同 wire——{type:'image', mediaType, data, name?}
			// 送给内核 session.prompt（内核做限额/降采样/附件落盘）；纯文本仍走 followup（零回归）。
			const content = text.trim() !== ""
				? [{ type: "text", text }, ...images.map((im) => ({ type: "image", mediaType: im.mediaType, data: im.data, ...(typeof im.name === "string" && im.name !== "" ? { name: im.name } : {}) }))]
				: images.map((im) => ({ type: "image", mediaType: im.mediaType, data: im.data, ...(typeof im.name === "string" && im.name !== "" ? { name: im.name } : {}) }));
			const hasImages = images.length > 0;
			// v3.0.0 排障仪表：记录 /send 收到的实际载荷形态（文本长度/图片数/分支）
			ctx.logger.info?.(`mobile-remote: /send hit → ${target.id} text=${text.length}B imgs=${images.length} steer=${steer} status=${target.status}`);
			const prompt = (mode) => promptImage(target.id, mode, content);
			const message = createUserMessage({ content: [{ type: "text", text }], source: { kind: "user" } });
			// v2.9.0 review(LOW #13)：followup/steer 同步抛错不裸奔——显式捕获映射，避免落 500 internal
			try {
				if (steer && target.status !== "idle" && typeof target.steer === "function") {
					if (hasImages) {
						await prompt("steer");
						sendJson(res, 200, { ok: true, agentId: target.id, mode: "steer", note: "image-prompt" });
					} else {
						target.steer(message);
						sendJson(res, 200, { ok: true, agentId: target.id, messageId: message.id, mode: "steer" });
					}
				} else if (target.status === "running") {
					// 运行中 + 排队（或空闲降级前的插队）：持存，任务结束才释放
					const heldEntry = hasImages
						? { id: message.id, text, images, at: Date.now() }
						: { id: message.id, text, at: Date.now() };
					heldQueue.set(target.id, [...heldOf(target.id), heldEntry]);
					persistHeld();
					broadcastQueue(target.id);
					sendJson(res, 200, {
						ok: true,
						agentId: target.id,
						messageId: message.id,
						mode: "queued",
						note: steer ? "steer-degraded-held" : "held-until-idle",
					});
				} else {
					if (steer && target.status === "idle") {
						// 空闲降级：返回 note 供客户端提示
						if (hasImages) {
							await prompt("queue");
							sendJson(res, 200, { ok: true, agentId: target.id, mode: "followup", note: "image-prompt" });
						} else {
							target.followup(message);
							sendJson(res, 200, { ok: true, agentId: target.id, messageId: message.id, mode: "followup", note: "agent-idle-followup" });
						}
						return;
					}
					if (hasImages) {
						await prompt("queue");
						sendJson(res, 200, { ok: true, agentId: target.id, mode: "followup", note: "image-prompt" });
					} else {
						target.followup(message);
						sendJson(res, 200, { ok: true, agentId: target.id, messageId: message.id, mode: "followup" });
					}
				}
			} catch (err) {
				ctx.logger.warn(`mobile-remote: send 失败：${err?.message ?? err}`);
				return error(res, 500, "send-failed", err?.message ?? String(err));
			}
			return;
		}

		// v3.0.0 图像链路：读取已入会话的图片（渲染用）——透传内核 session.attachment
		if (rest === "/attachment") {
			if (requireGet(method, res)) return;
			const sessionId = url.searchParams.get("sessionId");
			const attachmentId = url.searchParams.get("attachmentId");
			if (!sessionId || !attachmentId) return error(res, 400, "bad-request", "sessionId/attachmentId required");
			try {
				const value = await apiRpc("session.attachment", { sessionId, attachmentId }, 30_000);
				const ref = value?.attachment;
				if (!ref || typeof value?.data !== "string" || value.data === "") return error(res, 404, "attachment-not-found");
				const buf = Buffer.from(value.data, "base64");
				guardRes(res);
				res.writeHead(200, {
					"content-type": typeof ref.mediaType === "string" ? ref.mediaType : "image/jpeg",
					"content-length": buf.length,
					"cache-control": "private, max-age=3600",
					"x-attachment-meta": JSON.stringify({
						width: Number.isFinite(ref.width) ? ref.width : 0,
						height: Number.isFinite(ref.height) ? ref.height : 0,
						bytes: Number.isFinite(ref.bytes) ? ref.bytes : buf.length,
						name: typeof ref.name === "string" ? ref.name : null,
					}),
				});
				res.end(buf);
			} catch (err) {
				return error(res, ...rpcError(err, "attachment-failed"));
			}
			return;
		}

		// v2.7.2：排队消息视图（对齐 PC 端 Queue Dock）——读 agent.inbox 的 next-turn/next-step 队列
		// v3.0.0（方案 A）：视图 = 内核 inbox 行 + 插件持存行（运行中移动端排队的消息在插件侧暂存）
		if (rest === "/queue") {
			if (requireGet(method, res)) return;
			const sessionId = url.searchParams.get("sessionId");
			if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
			const sessions = ctx.get("sessions");
			const agents = ctx.get("agents");
			const agent = agents ? agents.get(sessionId) : undefined;
			if (!agent && !sessions?.get(sessionId)) return error(res, 404, "session-not-found");
			// 会话存在但无 agent（休眠）：仍可看到插件持存行（移动端排队消息不丢）
			sendJson(res, 200, { ok: true, queue: queueRowsOf(sessionId) });
			return;
		}

		// v2.7.2：对排队中消息的操作（对齐 PC 端 session.updateQueue）：edit / remove / steer
		// v3.0.0（方案 A）：插件持存行优先在插件侧处理（删除/编辑永远成功；插队=立即 steer 注入当前运行）
		if (rest === "/messages") {
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			const sessionId = typeof body?.sessionId === "string" ? body.sessionId : "";
			const itemId = typeof body?.itemId === "string" ? body.itemId : "";
			const action = body?.action;
			if (!sessionId || !itemId) return error(res, 400, "bad-request", "sessionId/itemId required");
			if (!action || !["edit", "remove", "steer"].includes(action.kind)) {
				return error(res, 400, "bad-request", "action.kind must be edit | remove | steer");
			}
			if (action.kind === "edit") {
				// review：edit 需非空且至少一个 text block（空 content 会让消息变空且无法再操作）
				if (!Array.isArray(action.content) || action.content.length === 0) {
					return error(res, 400, "bad-request", "edit requires non-empty content");
				}
				if (!action.content.some((b) => b?.type === "text" && typeof b.text === "string")) {
					return error(res, 400, "bad-request", "edit requires at least one text block");
				}
			}
			// ── 插件持存行分支 ──
			const held = [...heldOf(sessionId)];
			const heldIdx = held.findIndex((m) => m.id === itemId);
			if (heldIdx !== -1) {
				const agents = ctx.get("agents");
				const agent = agents?.get(sessionId);
				try {
					if (action.kind === "edit") {
						const newText = action.content.filter((b) => b?.type === "text").map((b) => b.text).join("");
						held[heldIdx] = { ...held[heldIdx], text: newText, at: Date.now() };
					} else if (action.kind === "remove") {
						held.splice(heldIdx, 1);
					} else {
						// steer：立即注入当前运行（下一步边界执行）；agent 刚好空闲则降级 followup
						const item = held.splice(heldIdx, 1)[0];
						if (item.images?.length) {
							// v3.0.0 图像链路：持存图片条目的插队 → 内核 prompt（运行中 steer/空闲 queue）
							const running = !!agent && agent.status !== "idle" && typeof agent.steer === "function";
							await promptImage(sessionId, running ? "steer" : "queue", heldContentOf(item));
						} else {
							const message = createUserMessage({ content: [{ type: "text", text: item.text }], source: { kind: "user" } });
							if (agent && agent.status !== "idle" && typeof agent.steer === "function") {
								agent.steer(message);
							} else if (agent) {
								agent.followup(message);
							}
						}
					}
					heldQueue.set(sessionId, held);
					persistHeld();
					broadcastQueue(sessionId);
					sendJson(res, 200, { ok: true, accepted: true });
				} catch (err) {
					return error(res, 500, "queue-hold-failed", err?.message ?? String(err));
				}
				return;
			}
			try {
				const value = await apiRpc("session.updateQueue", { sessionId, itemId, action });
				sendJson(res, 200, { ok: true, ...(value ?? {}) });
			} catch (err) {
				ctx.logger.warn(`mobile-remote: updateQueue failed: ${err?.message ?? err}`);
				return error(res, ...rpcError(err, "update-queue-failed"));
			}
			return;
		}

		if (rest === "/sessions" && method === "POST") {
			// 新建会话（移动端 v2）
			const body = await readJson(req, res);
			if (body === undefined) return;
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
			// v2.7.2 review：danger-full-access 确认校验必须在建会话之前（否则失败留下孤儿会话）
			if (typeof body.permissionPreset === "string" && body.permissionPreset === "danger-full-access" && body.confirmDanger !== true) {
				return error(res, 400, "risk-confirmation-required", "选择完全访问需显式确认风险");
			}
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
			if (requireGet(method, res)) return;
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
					// Phase 0(S8)：标题统一收敛——live 用会话标题、归档用快照标题，均兜底短码
					const title = (live ? sessionTitleOf(live) : titleMap.get(r.header.id)) ?? shortSessionId(r.header.id);
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
					// review：header 契约保证存在,但异常记录时不因缺字段打崩整个列表
					const h = session?.header;
					list.push({
						id: session?.id ?? "",
						createdAt: h?.createdAt,
						cwd: h?.cwd,
						live: true,
						// Phase 0(S8)：与 records 分支同款兜底短码，标题永不裸 null
						title: sessionTitleOf(session) ?? shortSessionId(session?.id ?? ""),
						archived: archived.has(session?.id),
						lastActivity: activityMap.get(session?.id) ?? null,
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
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			// v2.9.0 review(M#8)：touchActivity 已含 10s 去抖落盘，此处不再同步强写（原来每请求一次全量写盘）
			touchActivity(body.sessionId);
			sendJson(res, 200, { ok: true, lastActivity: activityMap.get(body.sessionId) });
			return;
		}

		if (rest === "/sessions/archive" || rest === "/sessions/unarchive") {
			// 归档/恢复会话：直接读写内核 workspaceRegistry 的归档状态（与 PC 端同一份）。
			// 归档后仍在列表返回中（archived: true），由客户端过滤展示。
			if (requirePost(method, res)) return;
			const archive = rest === "/sessions/archive";
			const body = await readJson(req, res);
			if (body === undefined) return;
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			try {
				if (archive) {
					await apiRpc("workspace.archiveSession", { sessionId: body.sessionId });
				} else {
					await unarchiveCore(body.sessionId);
				}
			} catch (err) {
				return error(res, ...rpcError(err, "archive-failed"));
			}
			sendJson(res, 200, { ok: true, archived: archive });
			return;
		}

		if (rest === "/sessions/fork") {
			// 在新对话中分支：映射内核 session.fork（atSeq 锚定已完成轮次的切点）
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			try {
				const child = await apiRpc("session.fork", {
					sessionId: body.sessionId,
					...(typeof body.atSeq === "number" && Number.isFinite(body.atSeq) ? { atSeq: body.atSeq } : {}),
				});
				sendJson(res, 200, { ok: true, sessionId: child.sessionId });
			} catch (err) {
				return error(res, ...rpcError(err, "fork-failed"));
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
				const body = await readJson(req, res);
				if (body === undefined) return;
				if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
				if (typeof body?.messageId !== "string" || body.messageId === "") return error(res, 400, "missing-messageId");
				if (body?.rating !== "positive" && body?.rating !== "negative" && body?.rating !== "none") {
					return error(res, 400, "invalid-rating");
				}
				const service = ctx.get("messageFeedback");
				if (!service?.put) return error(res, 503, "feedback-unavailable");
				try {
					// v2.7.2 review(M1)：内核 put 要求 ifVersion 与现有版本精确匹配（undefined 恒 version-conflict，
					// 此前 👍/👎 100% 失败）——客户端不传时先 list 读取该消息当前版本再写
					let ifVersion = typeof body.ifVersion === "string" ? body.ifVersion : undefined;
					if (ifVersion === undefined && typeof service.list === "function") {
						try {
							const listed = await service.list({ sessionId: body.sessionId });
							if (listed?.ok) {
								const existing = (listed.value?.items ?? []).find((i) => i.messageId === body.messageId);
								ifVersion = existing?.version ?? null;
							}
						} catch {
							ifVersion = null; // list 失败按新建处理
						}
					}
					// v2.8.0：rating=none = 取消反馈（toggle），删除该消息的反馈记录（与 PC 端取消一致）
					if (body.rating === "none") {
						if (typeof service.delete !== "function") return error(res, 503, "feedback-unavailable");
						const del = await service.delete({
							sessionId: body.sessionId,
							messageId: body.messageId,
							ifVersion,
						});
						if (!del?.ok) {
							const code = del?.error?.code;
							// v2.8.0 review：session-not-found 与 GET/put 分支一致映射 404
							const status = code === "version-conflict" ? 409 : code === "session-not-found" ? 404 : 400;
							return error(res, status, code ?? "feedback-failed", del?.error?.message ?? "feedback remove failed");
						}
						// v2.8.0 review：absent=true 表示本就不存在（toggle 幂等），removed 精确反映是否真正删除
						sendJson(res, 200, { ok: true, removed: del?.value?.absent !== true });
						return;
					}
					const result = await service.put({
						sessionId: body.sessionId,
						messageId: body.messageId,
						rating: body.rating,
						ifVersion,
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
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			if (typeof body?.sessionId !== "string" || body.sessionId === "") return error(res, 400, "missing-sessionId");
			try {
				await apiRpc("session.cancel", { sessionId: body.sessionId });
			} catch (err) {
				return error(res, ...rpcError(err, "cancel-failed"));
			}
			sendJson(res, 200, { ok: true, accepted: true });
			return;
		}

		if (rest === "/history") {
			if (requireGet(method, res)) return;
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
			const limit = Math.max(1, Math.min(Number(url.searchParams.get("limit") ?? 500) || 500, 1000));
			// 只保留表面事件（过滤 token 级 chunk 等海量日志型事件）
			const surface = session.events.filter((event) => SURFACE_TYPES.has(event.type));
			let events;
			if (afterParam !== null) {
				// 增量补漏：seq > after（SSE 重连后使用）
				const after = Number(afterParam) || 0;
				events = surface.filter((event) => event.seq > after).slice(0, limit);
			} else if (beforeParam !== null) {
				// 上翻分页：seq < before 的最近 limit 条（对话内往上翻加载更早）
				// v2.9.0 review(LOW #18)：before=0 语义为"更早的 0 条"（空），
				// 不能再用 || 兜底成 MAX_SAFE_INTEGER（会把分页上翻误判为初始加载）
				const beforeRaw = parseInt(beforeParam, 10);
				const before = Number.isNaN(beforeRaw) ? Number.MAX_SAFE_INTEGER : beforeRaw;
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
			// review：HEAD 会悬挂 SSE 连接（Node 对 HEAD 丢弃 body 但连接保持打开）——
			// 必须严格 GET-only，不能走 requireGet（其放行 HEAD）
			if (method !== "GET") return error(res, 405, "method-not-allowed");
			connect(res);
			return;
		}

		// ── 移动端 v2：目录 / 配置 / 新建会话 / 通知 / 动作 ──
		if (rest === "/catalog") {
			if (requireGet(method, res)) return;
			// 目录缓存（15 秒）：避免每次打开页面都重新探测模型/预设
			const now = Date.now();
			if (catalogCache && now - catalogCache.at < 15000) {
				sendJson(res, 200, catalogCache.body);
				return;
			}
			const agents = ctx.get("agents");
			const sessions = ctx.get("sessions");
			const first = firstAgent(agents);
			const models = [];
			const reasoningEfforts = new Set();
			const pushModels = async (provider, list) => {
				for (const model of list ?? []) {
					models.push({
						provider,
						id: model.id,
						name: model.name ?? model.id,
						...(model.description === void 0 ? {} : { description: model.description }),
						...(model.contextWindow === void 0 ? {} : { contextWindow: model.contextWindow }),
						// v3.0.0 图像链路：模型图片能力标注（inputModalities 含 "image"）
						...(llmRef ? { imageSupported: await imageSupportedOf(provider, model.id) } : {}),
					});
					for (const effort of model.reasoning?.efforts ?? []) reasoningEfforts.add(effort.id);
				}
			};
			const llmRef = ctx.get("llm");
			// v3.0.0 图像链路：模型图片能力（llm.resolveModelInfo → inputModalities），会话级缓存
			const imageSupportedCache = new Map();
			const imageSupportedOf = async (provider, modelId) => {
				const key = `${provider}/${modelId}`;
				if (imageSupportedCache.has(key)) return imageSupportedCache.get(key);
				let ok = false;
				try {
					const info = await llmRef.resolveModelInfo(provider, modelId);
					ok = Array.isArray(info?.inputModalities) && info.inputModalities.includes("image");
				} catch {
					ok = false;
				}
				imageSupportedCache.set(key, ok);
				return ok;
			};
			// v3.0.0 图像链路：限额从内核 session.history projections 取（与 PC 端同一组数字），取不到用内核默认
			const imageLimitsDefaults = {
				maxImageBytes: 20 * 1024 * 1024,
				maxImagesPerMessage: 20,
				maxMessageImageBytes: 20 * 1024 * 1024,
				maxImagePixels: 64e6,
				maxImageDimension: 8192,
				mediaTypes: ["image/png", "image/jpeg", "image/webp", "image/gif"],
			};
			let imageLimitsCache = { at: 0, value: null };
			const imageLimitsOf = async (sessionId) => {
				if (imageLimitsCache.value && Date.now() - imageLimitsCache.at < 5 * 60 * 1000) return imageLimitsCache.value;
				try {
					const value = await apiRpc("session.history", { sessionId, maxMessages: 1 }, 15000);
					const limits = value?.projections?.attachments?.imageLimits ?? null;
					if (limits && typeof limits === "object") {
						imageLimitsCache = { at: Date.now(), value: { ...imageLimitsDefaults, ...limits } };
						return imageLimitsCache.value;
					}
				} catch {
					// 拿不到：兜底默认
				}
				return imageLimitsDefaults;
			};
			let providers = [];
			try {
				const llm = ctx.get("llm");
				if (first) {
					const directory = await apiRpc("session.models", { sessionId: first.id });
					for (const group of directory?.groups ?? []) await pushModels(group.id, group.models);
				} else if (llm) {
					// 无运行中 agent：直接遍历全部提供商（v2.6 起不再写死 deepseek-official）
					for (const p of await llm.listProviders()) {
						await pushModels(p.id, await llm.listModels(p.id));
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
			// review：readSessionConfig 可能抛（会话事件结构异常），只查一次，失败不阻塞 catalog
			let firstCfg;
			try {
				firstCfg = first ? await readSessionConfig(first.id) : undefined;
			} catch {
				firstCfg = undefined;
			}
			const defaults = {
				model: firstCfg?.model,
				reasoningEffort: firstCfg?.reasoningEffort,
				permissionPreset: permissionPresets?.defaultSettings?.()?.defaultPreset,
				agentPreset: ctx.get("agentPresets")?.defaultId,
			};
			// v3.0.0 图像链路：图片限额下发（App 端发送前同 PC 端限制提示）
			const imageLimits = first ? await imageLimitsOf(first.id) : imageLimitsDefaults;
			catalogCache = { at: now, body: {
				ok: true,
				models,
				providers,
				reasoningEfforts: [...reasoningEfforts],
				permissionPresets: permissionList,
				agentPresets,
				defaults,
				imageLimits,
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
				const body = await readJson(req, res);
				if (body === undefined) return;
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
				// v2.9.0 review(M#12)：settings.mutate/credentials.set 在 HTTP 回调直调（无 fiber），
				// 失败不能裸抛（会沿 handleApi 外层 catch 落 500 internal）——显式捕获映射 4xx+ 日志
				try {
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
				} catch (err) {
					ctx.logger.warn(`mobile-remote: llm-providers 写入失败：${err?.message ?? err}`);
					return error(res, err?.status ?? 400, "provider-write-failed", err?.message ?? String(err));
				}
				sendJson(res, 200, { ok: true, provider, apiKeyRef: ref, keyConfigured: apiKey !== "" });
				return;
			}
			return error(res, 405, "method-not-allowed");
		}

		if (rest === "/llm-providers/probe") {
			if (requirePost(method, res)) return;
			const llm = ctx.get("llm");
			if (!llm) return error(res, 503, "llm-unavailable");
			const body = await readJson(req, res);
			if (body === undefined) return;
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
				body = await readJson(req, res);
				if (body === undefined) return;
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
						return error(res, ...rpcError(err, "model-select-failed"));
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
			if (requireGet(method, res)) return;
			const items = [...notifStore.values()]
				.sort((a, b) => b.time - a.time)
				.map((n) => ({ ...n, unread: !readIds.has(n.id) }));
			sendJson(res, 200, { ok: true, unread: items.filter((n) => n.unread).length, items: items.slice(0, NOTIF_MAX) });
			return;
		}

		if (rest === "/notifications/read") {
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			if (body?.all === true) {
				for (const id of notifStore.keys()) readIds.add(id);
			} else if (Array.isArray(body?.ids)) {
				// v2.7.2 review：只接受存在于 notifStore 的 id 并限数量，
				// 防任意 id 注入导致 readIds 无界膨胀 + 每次同步写盘阻塞事件循环
				for (const id of body.ids.slice(0, 500)) {
					const s = String(id);
					if (notifStore.has(s)) readIds.add(s);
				}
			} else {
				return error(res, 400, "bad-request", "expected { ids } or { all: true }");
			}
			scheduleReadPersist();
			sendJson(res, 200, { ok: true });
			return;
		}

		if (rest === "/notifications/delete") {
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			// 删除通知记录（移动端通知镜像；不影响 PC 端自己的通知中心）。
			// 仅移除记录本身：后续新事件仍会正常生成新通知（不设墓碑、不静音会话）。
			if (body?.all === true) {
				for (const id of notifStore.keys()) readIds.delete(id);
				notifStore.clear();
			} else if (Array.isArray(body?.ids)) {
				// v2.9.0 review(M#10)：与 /read 对齐的 500 上限，防超大批量请求
				for (const id of body.ids.slice(0, 500)) {
					notifStore.delete(String(id));
					readIds.delete(String(id));
				}
			} else {
				return error(res, 400, "bad-request", "expected { ids } or { all: true }");
			}
			scheduleReadPersist();
			broadcast({ type: "notifications/changed" });
			sendJson(res, 200, { ok: true });
			return;
		}

		if (rest === "/respond") {
			// 移动端回答内核问询/审批：经 apiProxy.respond 走与 PC 端 GUI 完全相同的
			// 校验与结算通道（pending 表、matchesQuestions、approval 决策等由内核把关）。
			if (requirePost(method, res)) return;
			if (!proxy || typeof proxy.respond !== "function") return error(res, 503, "respond-unavailable", "内核 apiProxy 不可用（请升级 dsh）");
			const body = await readJson(req, res);
			if (body === undefined) return;
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
				// review：此前伪装成 200（accepted:false），客户端与日志都难发现失败
				ctx.logger.warn(`mobile-remote: respond failed: ${e?.message ?? e}`);
				return error(res, 500, "respond-failed", String(e?.message ?? e));
			}
			return;
		}

		if (rest === "/actions") {
			if (requireGet(method, res)) return;
			sendJson(res, 200, { ok: true, actions: mobileActions.list() });
			return;
		}

		// ── 余额查询（DeepSeek 官方 /user/balance，key 不经过移动端） ──
		if (rest === "/balance") {
			if (requireGet(method, res)) return;
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
			if (requireGet(method, res)) return;
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
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			try {
				if (typeof body.agentPreset === "string" && body.agentPreset !== "") {
					await apiRpc("settings.update", { ns: "agent-presets", patch: { default: body.agentPreset } });
				}
				if (typeof body.permissionPreset === "string" && body.permissionPreset !== "") {
					await apiRpc("settings.update", { ns: "permission", patch: { defaultPreset: body.permissionPreset } });
				}
				sendJson(res, 200, { ok: true });
			} catch (e) {
				error(res, ...rpcError(e, "update-failed"));
			}
			return;
		}

		// ── 环境诊断（能力探测，让个性化差异可见） ──
		if (rest === "/diagnostics") {
			if (requireGet(method, res)) return;
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
				// v2.8.0 review：与 /catalog 同款 firstAgent 语义（roots 优先，无 root 退回 list 首项）
				const sid = firstAgent(agents)?.id;
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
					// v2.9.0：LAN 桥状态（enabled/配置端口 vs listening=实际监听成功；绑定失败时 QR/地址已回退）
					lanBridge: { enabled: lanEnabled, host: lanHost, port: lanPort, listening: lanBridgeListening },
				},
				services,
				checks,
			});
			return;
		}

		// ── 工作区与目录浏览（移动端新建会话选工作目录） ──
		if (rest === "/workspaces") {
			if (requireGet(method, res)) return;
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
				const body = await readJson(req, res);
				if (body === undefined) return;
				const parent = typeof body.path === "string" && body.path !== "" ? body.path : undefined;
				const name = typeof body.name === "string" ? body.name.trim() : "";
				if (name === "" || name === "." || name === ".." || /[\\/:*?"<>|]/.test(name)) return error(res, 400, "invalid-name", "文件夹名不合法");
				try {
					const target = parent ? join(parent, name) : name;
					mkdirSync(target, { recursive: false });
					sendJson(res, 200, { ok: true, path: target });
				} catch (err) {
					return error(res, 400, "mkdir-failed", err.message);
				}
				return;
			}
			if (requireGet(method, res)) return;
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
			let id;
			try {
				// review：非法百分号编码（%zz）会让 decodeURIComponent 抛 URIError → 应 400 而非 500
				id = decodeURIComponent(actionMatch[1]);
			} catch (err) {
				return bodyError(err, res);
			}
			const entry = actionEntries.get(id);
			if (!entry) return error(res, 404, "action-not-found");
			const body = await readJson(req, res);
			if (body === undefined) return;
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
			if (requireGet(method, res)) return;
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
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
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
			if (requireGet(method, res)) return;
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
				return error(res, ...rpcError(err, "subagent-list-failed"));
			}
			return;
		}
		if (rest === "/subagents/interrupt") {
			if (requirePost(method, res)) return;
			const body = await readJson(req, res);
			if (body === undefined) return;
			const parentSessionId = typeof body.parentSessionId === "string" ? body.parentSessionId : "";
			const childSessionId = typeof body.childSessionId === "string" ? body.childSessionId : "";
			if (!parentSessionId || !childSessionId) return error(res, 400, "parentSessionId-and-childSessionId-required");
			try {
				await apiRpc("subagent.interrupt", { parentSessionId, childSessionId, mode: "continuable" });
				sendJson(res, 200, { ok: true });
			} catch (err) {
				return error(res, ...rpcError(err, "subagent-interrupt-failed"));
			}
			return;
		}
		if (rest === "/commands") {
			// v2.8.0：斜杠命令目录（对齐 PC 端 ctx.commands）——GET 列出、POST 执行
			// v2.8.2 适配：commands 服务可能未注册（desktop profile / 旧 DSH 无 dsh-commands host 服务）——
			// 优雅返回空列表 + unavailable 标记，不硬 503（App 端点击命令入口时弹"无可用命令"提示）
			const agents = ctx.get("agents");
			const commands = ctx.get("commands");
			if (method === "GET" || method === "HEAD") {
				const sessionId = url.searchParams.get("sessionId");
				if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
				const agent = agents ? agents.get(sessionId) : undefined;
				if (!commands) {
					// 兼容：commands 服务未注册（desktop profile / 旧 DSH 无 dsh-commands host 服务）——
					// 返回空列表 + unavailable 标记，不硬 503（App 端点击命令入口时弹"无可用命令"提示）
					sendJson(res, 200, { ok: true, commands: [], unavailable: true });
					return;
				}
				// 服务在而会话不存在（如 DSH 升级后旧会话被迁移丢弃）：显式 404，不掩盖真实原因
				if (!agent) return error(res, 404, "session-not-found", `session not found: ${sessionId}`);
				try {
					const list = commands.list(agent);
					sendJson(res, 200, {
						ok: true,
						commands: (list ?? []).map((c) => ({
							name: c.name,
							description: c.description,
							...(c.input ? { input: c.input } : {}),
						})),
					});
				} catch (err) {
					return error(res, 400, "commands-list-failed", err?.message ?? String(err));
				}
				return;
			}
			if (method === "POST") {
				const body = await readJson(req, res);
				if (body === undefined) return;
				const sessionId = typeof body.sessionId === "string" ? body.sessionId : "";
				const line = typeof body.line === "string" ? body.line : "";
				if (!sessionId) return error(res, 400, "missing-sessionId");
				if (!line || !line.startsWith("/")) return error(res, 400, "bad-request", "line must start with /");
				const agent = sessionId && agents ? agents.get(sessionId) : undefined;
				if (!commands) return error(res, 503, "commands-unavailable", "commands service not available in this DSH");
				// 服务在而会话不存在：显式 404（与 GET 拆分语义一致，不再与 503 混报）
				if (!agent) return error(res, 404, "session-not-found", `session not found: ${sessionId}`);
				try {
					// v2.8.2 适配 0.1.1-rc.2：内核签名 (agent, line, images, signal)，images 为空数组（图片附件暂不支持）
					const result = await commands.execute(agent, line, [], AbortSignal.timeout(15000));
					// v2.8.0 review：内核 execute 对未知/畸形命令返回 undefined 而非抛错——
					// 必须显式 404，否则客户端误判"执行成功"（对齐 PC 端 unknown command 提示）
					if (result === undefined) {
						return error(res, 404, "command-not-found", `unknown or malformed command: ${line}`);
					}
					sendJson(res, 200, { ok: true, result });
				} catch (err) {
					return error(res, ...rpcError(err, "commands-execute-failed"));
				}
				return;
			}
			return error(res, 405, "method-not-allowed");
		}
		if (rest === "/goal") {
			const agents = ctx.get("agents");
			if (method === "GET" || method === "HEAD") {
				const sessionId = url.searchParams.get("sessionId");
				// review：缺 sessionId 语义是 400（此前误报 503 goal-unavailable）
				if (!sessionId) return error(res, 400, "bad-request", "missing sessionId");
				const agent = agents ? agents.get(sessionId) : undefined;
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
				const body = await readJson(req, res);
				if (body === undefined) return;
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
							// v2.9.0 review(LOW #17)：maxGoalRounds 校验（1-10000 整数），非法值显式 400 而非转发内核
							const rounds = body.maxGoalRounds;
							if (rounds !== undefined && (!Number.isInteger(rounds) || rounds < 1 || rounds > 10000)) {
								return error(res, 400, "maxGoalRounds-invalid", "maxGoalRounds must be an integer 1-10000");
							}
							await apiRpc("goal.create", {
								sessionId,
								objective,
								...(rounds === undefined ? {} : { maxGoalRounds: rounds }),
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
					return error(res, ...rpcError(err, "goal-failed"));
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
		// v3.0.0（方案 A）：移动端持存排队消息（插件重启不丢，agent 空闲后释放）
		loadHeld();
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
								pendingFrameSet(key, { ...frame, rpcId: envelope.rpcId });
								broadcast({ type: "mobile/frame", frame: { ...frame, rpcId: envelope.rpcId } });
								// v2.7.2（问题三）：审批/提问 → 立即生成 needs-answer 通知 + 推送——
								// App 后台/被杀、悬浮球未开时也能收到提醒（turn/end blocked 之外的独立通道）；
								// review M2：与 blocked 路径共用时间窗去重
								const askSessionId = typeof frame.sessionId === "string" ? frame.sessionId : "";
								if (askSessionId) {
									const askDetail = frame.type === "approval/requested"
										? `审批请求：${typeof frame.toolName === "string" && frame.toolName ? frame.toolName : "工具"} 需要授权`
										: "agent 正在等待你的回答";
									notifyNeedsAnswer(askSessionId, askDetail);
								}
							} else if (frame.type === "question/resolved") {
								// review(M3)：防御——两种 key 形态都删（questionRpcId 与 rpcId 同值，双删无副作用）
								pendingFrames.delete(`q:${frame.questionRpcId}`);
								pendingFrames.delete(`q:${envelope.rpcId}`);
								broadcast({ type: "mobile/frame", frame: { ...frame } });
							} else if (frame.type === "approval/resolved") {
								pendingFrames.delete(`a:${frame.approvalId}`);
								pendingFrames.delete(`a:${envelope.rpcId}`);
								broadcast({ type: "mobile/frame", frame: { ...frame } });
							} else if (frame.type === "session/queue") {
								// v3.0.0：内核每次 inbox 变化都会广播 session/queue 快照（认领/删除/编辑
								// 即时反映），归一化为 mobile/queue 帧推给 App（与 GET /queue 同款 rows 形状，
								// 并合并插件持存行）。App 端 dock 以帧为权威源。
								const sid = typeof frame.sessionId === "string" ? frame.sessionId : "";
								broadcast({ type: "mobile/queue", sessionId: sid, rows: queueRowsOf(sid) });
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
		// ── LAN 桥（v2.9.0）━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
		// 桌面版（dsh-plugin-desktop）强制 webserver 只听 127.0.0.1（DesktopWebServer 构造器
		// 对非回环 host 直接 throw，用户 patch 也覆盖不了），手机无法直连 → 插件在 DSH 进程内
		// 自建 HTTP 监听，把 `${basePath}` 前缀请求**流式**转发到回环 webserver（SSE 长连可透传）。
		// 安全边界：①只转发移动端面；②`/api` 网关（桌面 GUI 内部 RPC）、`qr-config`、`qr.png`
		// （含 token / 仅本机语义）一律不转发；③未配置 authToken 拒绝启动（LAN 暴露必须强口令）；
		// ④Host 头重写为回环信任值 → 下游 hostAllowed 自然放行，真实鉴权仍由 token 把关。
		if (lanEnabled) {
			if (!authEnabled) {
				ctx.logger.warn(
					"mobile-remote: lanBridge 已启用但未配置 authToken —— 拒绝启动（LAN 暴露必须强口令，见 docs/04-security.md）"
				);
			} else if (config.authToken.length < 16) {
				// v2.9.0 review(B6)：LAN 暴露必须 ≥16 字符强口令（与 docs/04-security §2.1 承诺一致）；
				// 不做 schema min() 以免破坏既有用户加载——仅桥路径强制
				ctx.logger.warn(
					"mobile-remote: lanBridge 已启用但 authToken 短于 16 字符 —— 拒绝启动（LAN 暴露必须 ≥16 字符强随机口令）"
				);
			} else {
				try {
					lanServer = createHttpServer((req, res) => {
						lanBridgeSockets.add(req.socket);
						res.on("close", () => lanBridgeSockets.delete(req.socket));
						const pathname = new URL(req.url ?? "/", "http://x").pathname;
						// 只转发移动端 API 面（/m/api*）；任何编码/双斜杠/大小写变体到最后都会因
						// 上游 handleApi 的 rest 字面切片 ≠ 已知路由而 404；
						// **qr-config 必须显式排除**（唯一回传 authToken 的端点，LAN 不可达为硬性要求，
						// 见 docs/04-security §3b）；qr.png（不以 /m/api 开头天然排除）、
						// 桌面 /api RPC 网关、/m 下其它面一律 404。
						if (!pathname.startsWith(`${basePath}/api`) || pathname === `${basePath}/api/qr-config`) {
							res.writeHead(404);
							res.end();
							return;
						}
						const upstreamHeaders = { ...req.headers };
						delete upstreamHeaders.host;
						delete upstreamHeaders.connection;
						delete upstreamHeaders["x-forwarded-for"];
						delete upstreamHeaders["x-forwarded-host"];
						delete upstreamHeaders["x-forwarded-proto"];
						delete upstreamHeaders.via;
						upstreamHeaders.host = `127.0.0.1:${ctx.webServer.port}`;
						const upstream = httpRequest(`http://127.0.0.1:${ctx.webServer.port}${req.url ?? "/"}`, {
							method: req.method,
							headers: upstreamHeaders,
						});
						// 上游 15s 无响应（含慢 body）→ 断开，防 LAN 未鉴权请求挂起耗尽 socket。
						// **SSE 长连例外（v3.0.0 收窄）**：插件心跳 25s 间隔 > 15s 空闲会被误杀
						// （手机端表现为每条长连 15 秒即断、重连风暴）——events 路径超时放大到 60s：
						// 心跳/帧流每 25s 必然有一次 socket 活动，60s 不会被误杀；
						// 也不像"完全不设超时"那样让静默死链的上游 socket 成为僵尸（无回收、占满配额）。
						// v3.0.0(图像链路)：普通请求 15s→180s——手机上传 20MB 级 base64 图片经桥转发
						// 超过 15s 空闲即被销毁("Connection reset by peer"/"upstream webserver unreachable"),
						// 180s 覆盖大 body 上传+内核处理时延,僵尸防护由桥层 headersTimeout 15s 兜底。
						const isSse = pathname === `${basePath}/api/events`;
						upstream.setTimeout(isSse ? 60_000 : 180_000, () => upstream.destroy());
						guardRes(res);
						res.on("close", () => upstream.destroy());
						upstream.on("response", (upRes) => {
							res.writeHead(upRes.statusCode ?? 502, upRes.headers);
							upRes.pipe(res);
							upRes.on("error", () => res.destroy());
						});
						upstream.on("error", () => {
							if (res.headersSent) {
								res.destroy();
								return;
							}
							res.writeHead(502, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
							res.end(JSON.stringify({ error: "bridge-unavailable", detail: "upstream webserver unreachable" }));
						});
						req.pipe(upstream);
					});
					// v2.9.0 review：LAN 面防资源耗尽——连接上限、慢速头/体超时（SSE 不受影响：
					// 请求头已收齐即视为超时窗口结束，长连只受 upstream/SSE 心跳与背压控制）
					// v3.0.0(图像链路)：requestTimeout 60s→180s——20MB 级 base64 图片上传经桥
					// 转发可能超过 60s(手机热点上行慢);慢头仍由 headersTimeout 15s 拦截
					lanServer.maxConnections = 128;
					lanServer.headersTimeout = 15_000;
					lanServer.requestTimeout = 180_000;
					lanServer.on("error", (err) => {
						lanBridgeListening = false;
						ctx.logger.warn(`mobile-remote: lanBridge 监听错误：${err?.message ?? err}`);
					});
					lanServer.on("close", () => {
						lanBridgeListening = false;
					});
					lanServer.listen(lanPort, lanHost, () => {
						lanBridgeListening = true;
						ctx.logger.info?.(`mobile-remote: lanBridge 已监听 ${lanHost}:${lanPort} → 127.0.0.1:${ctx.webServer.port}${basePath}/api`);
					});
				} catch (err) {
					lanBridgeListening = false;
					ctx.logger.warn(`mobile-remote: lanBridge 启动失败：${err?.message ?? err}`);
				}
			}
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
					} catch (err) {
						return bodyError(err, res);
					}
					const rest = url.pathname.slice(basePath.length + "/api".length);
					handleApi(req, res, url, rest).catch((err) => {
						// v2.7.2 review(S2)：catch 内再抛会变成 unhandled rejection 崩进程，
						// 记录日志并 try/catch 包裹兜底响应
						ctx.logger.warn(`mobile-remote: api handler error: ${err?.message ?? err}`);
						try {
							if (!res.headersSent) error(res, 500, "internal");
							else res.destroy();
						} catch {
							res.destroy?.();
						}
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
					} catch (err) {
						return bodyError(err, res);
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
		// v2.7.2 review(M3/M4)：会话销毁 → 清理该会话全部跟踪状态（通知判定/活跃度/上下文/挂起帧）
		const unsubscribeDisposed = ctx.on("agent/disposed", ({ agent }) => {
			const sid = agentSessionId(agent);
			if (!sid) return;
			cancelDone(sid);
			activityMap.delete(sid);
			contextWindowMap.delete(sid);
			titleCache.delete(sid);
			lastNeedsAnswerAt.delete(sid);
			pendingEpochs.delete(sid);
			// v3.0.0（方案 A）：会话销毁 → 持存排队消息一并清理（已被认领/丢弃语义，PC 端同理）
			if (heldQueue.has(sid)) {
				heldQueue.delete(sid);
				persistHeld();
			}
			for (const [key, f] of pendingFrames) {
				if (f.sessionId === sid) pendingFrames.delete(key);
			}
		});
		// v2.7.2 review(M4)：定期剪枝无界 Map（每 10 分钟）
		const pruneTimer = setInterval(() => {
			const now = Date.now();
			const HOUR = 3600 * 1000;
			for (const [k, t] of pushCooldowns) if (typeof t === "number" && now - t > 24 * HOUR) pushCooldowns.delete(k);
			for (const [k, t] of lastNeedsAnswerAt) if (typeof t === "number" && now - t > 10 * 60 * 1000) lastNeedsAnswerAt.delete(k);
			for (const [k, v] of titleCache) if (typeof v?.at === "number" && now - v.at > TITLE_CACHE_TTL) titleCache.delete(k);
			for (const [k, t] of activityMap) if (typeof t === "number" && now - t > 7 * 24 * HOUR) activityMap.delete(k);
		}, 10 * 60 * 1000);
		pruneTimer.unref?.();
		// v3.0.0（方案 A）：持存消息释放守卫——agent/status idle 与 restart 恢复之外的兜底：
		// 每 30s 检查会话是否存在且空闲（插件重启后 agent 重载可能不再触发 idle 事件）
		const heldSweepTimer = setInterval(() => {
			const agents = ctx.get("agents");
			for (const sid of heldQueue.keys()) {
				const agent = agents?.get(sid);
				if (agent && agent.status === "idle") releaseHeld(sid);
			}
		}, 30_000);
		heldSweepTimer.unref?.();
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
					// review：心跳也做背压检查——卡死但不报错的慢客户端靠 5B/25s 永远到不了踢线
					if (typeof res.writableLength === "number" && res.writableLength > 256 * 1024) {
						dropConn(res);
					}
				} catch {
					dropConn(res); // 心跳写失败 → 僵尸连接立即清理
				}
			}
		}, 25000);
		heartbeat.unref();
		return () => {
			// v2.9.0 review(M#8)：卸载前冲刷未落盘的已读/活跃时间（去抖数据不丢）
			if (readPersistTimer) {
				clearTimeout(readPersistTimer);
				persistReadIds();
			}
			if (activityPersistTimer) {
				clearTimeout(activityPersistTimer);
				persistActivityNow();
			}
			for (const dispose of disposers) dispose();
			// v2.9.0：LAN 桥随插件卸载关闭（含在网连接，不留半开）
			try {
				lanServer?.close();
			} catch {}
			for (const socket of lanBridgeSockets) {
				try {
					socket.destroy();
				} catch {}
			}
			lanBridgeSockets.clear();
			lanServer = null;
			lanBridgeListening = false;
			unsubscribeSession();
			unsubscribeStatus();
			unsubscribeDisposed?.();
			clearInterval(pruneTimer);
			clearInterval(heldSweepTimer);
			persistHeld(); // 卸载前冲刷持存排队消息
			// v2.7.2 review：卸载时清理全部定时器与跟踪状态（避免对已 dispose 的 ctx 触发回调）
			for (const t of doneTimers.values()) clearTimeout(t);
			doneTimers.clear();
			pendingOutcomes.clear();
			pendingEpochs.clear();
			lastNeedsAnswerAt.clear();
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
