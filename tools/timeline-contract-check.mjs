// Issue #1：可见事件协议的无损指针/未知事件/工具关联回归。
// 需要 DSH_MOBILE_PLUGIN 指向可加载的插件模块；与现有 hotfix07-unit-check 同一导入策略。
import { pathToFileURL } from "node:url";

const configuredPath = process.env.DSH_MOBILE_PLUGIN;
const selectedPath = configuredPath ?? new URL("../lib/index.js", import.meta.url).pathname;
const importPath = /^[a-zA-Z]:[\\/]/.test(selectedPath) ? pathToFileURL(selectedPath).href : selectedPath;
let mod;
try {
  mod = await import(importPath);
  console.log(`插件模块：${selectedPath}`);
} catch (error) {
  console.error(`FAIL: 无法导入指定插件模块 ${selectedPath}: ${error?.message ?? error}`);
  process.exit(1);
}

let pass = 0;
let fail = 0;
const check = (name, condition, detail = "") => {
  if (condition) {
    pass++;
    console.log(`PASS ${name}`);
  } else {
    fail++;
    console.log(`FAIL ${name}${detail ? ` ← ${detail}` : ""}`);
  }
};

const unknown = { seq: 7, type: "future/visible", data: { secretLike: "raw-value" } };
const summary = mod.summarizeEvent(unknown);
check("未知事件保留 type/seq", summary.type === unknown.type && summary.seq === unknown.seq);
// PR #24 复核：详情端点改为 fail-closed（allow-list），未知类型不再声明必然 404 的详情指针。
check("未知事件不再声明详情指针（fail-closed）", summary.detail === undefined, JSON.stringify(summary.detail));
check("未知事件摘要不下发原始 data", summary.data === undefined, JSON.stringify(summary.data));
check("未知事件可进入历史时间线", mod.isTimelineRecord(unknown) === true);
check("ignorable 未知事件仍保留 opaque identity", mod.isTimelineRecord({ seq: 8, type: "future/ignorable", ignorable: true, data: {} }) === true);
check("敏感/内部事件不进入时间线", ["request/header", "request/context", "system/message", "step/start", "compaction/end"].every((type) => mod.isTimelineRecord({ seq: 8, type, data: {} }) === false));
check("重建/压缩快照不进入时间线", ["assistant/attempt", "compaction/start", "compaction/summary", "compaction/prune"].every((type) => mod.isTimelineRecord({ seq: 8, type, data: {} }) === false));
check("token chunk 不进入历史时间线", mod.isTimelineRecord({ seq: 8, type: "assistant/chunk", data: {} }) === false);
check("token chunk 仍进入实时流", mod.isLiveTimelineRecord({ seq: 8, type: "assistant/chunk", data: {} }) === true);
check("内部事件不进入实时 session/event", mod.isLiveTimelineRecord({ seq: 8, type: "request/header", data: {} }) === false);
check("compaction 控制事件进入实时但不进历史", mod.isLiveTimelineRecord({ seq: 8, type: "compaction/end", data: {} }) === true && mod.isTimelineRecord({ seq: 8, type: "compaction/end", data: {} }) === false);

// PR #24 复核（阻断级泄露）：LLM 请求快照含 system prompt / messages 正文，按命名约定拦截。
const llmRequestTypes = ["session/title-llm-request", "web/deepseek-search-llm-request", "web/future-provider-llm-request", "future/llm-request"];
check("LLM 请求快照不进入历史时间线", llmRequestTypes.every((type) => mod.isTimelineRecord({ seq: 8, type, data: { system: "SECRET" } }) === false));
check("LLM 请求快照不进入实时流", llmRequestTypes.every((type) => mod.isLiveTimelineRecord({ seq: 8, type, data: { system: "SECRET" } }) === false));
check("LLM 请求快照不声明详情指针", llmRequestTypes.every((type) => mod.summarizeEvent({ seq: 8, type, data: { system: "SECRET" } }).detail === undefined));
check(
  "llm-request 规则按段边界匹配、不误伤其它类型",
  mod.isTimelineRecord({ seq: 8, type: "future/llm-request-note", data: {} }) === true
    && mod.isTimelineRecord({ seq: 8, type: "future/visible", data: {} }) === true
    && mod.isTimelineRecord({ seq: 8, type: "assistant/live-chunk", data: {} }) === false,
  "future/llm-request-note 仍应保留",
);
check("详情 allow-list 只放行 App 真正消费的类型", ["user/message", "assistant/message", "tool/call", "tool/result", "todo/write", "turn/start", "turn/end"].every((type) => mod.isDetailVisibleType(type) === true));
check("详情 allow-list 拒绝协议元数据/未知/未命名类型", ["session/title", "model/selection", "approval/asked", "question/requested", "session/jobs", "subagent/descriptor", "future/visible", "request/something-new", "session/title-llm-request"].every((type) => mod.isDetailVisibleType(type) === false));
check("实时草稿类型无详情可读（未落 durable 历史）", mod.isDetailVisibleType("assistant/chunk") === false && mod.isDetailVisibleType("assistant/live-chunk") === false);

const toolDelta = mod.summarizeEvent({
  seq: 9,
  type: "assistant/chunk",
  data: { turn: 1, step: 2, chunk: { type: "tool-call-delta", id: "call-1", name: "read_file", argumentsDelta: "{}" } },
});
check("工具参数增量保留 canonical chunk.id", toolDelta.data?.callId === "call-1");
check("实时草稿不声明不可取的详情指针", toolDelta.detail === undefined, JSON.stringify(toolDelta.detail));
const visibleCall = mod.summarizeEvent({ seq: 30, type: "tool/call", data: { turn: 1, step: 1, callId: "call-1", name: "shell", arguments: "ls" } });
check("可见事件声明详情指针", visibleCall.detail?.available === true && visibleCall.detail.seq === 30);
const structuredCall = mod.summarizeEvent({ seq: 11, type: "tool/call", data: { callId: "call-structured", name: "shell", arguments: { command: "ls", cwd: "/tmp" } } });
check("结构化工具参数不退化为 [object Object]", structuredCall.data?.arguments?.includes('"command"') === true);

// issue #1 需求变更：正文口径收敛（摘要与详情共用 blocksToText、跳过 reasoning）+ 详情指针长度提示
const reasoningMessage = mod.summarizeEvent({
  seq: 12,
  type: "assistant/message",
  data: { turn: 1, step: 1, message: { id: "m1", content: [
    { type: "reasoning", text: "THINKING-CHAIN" },
    { type: "text", text: "VISIBLE-BODY" },
  ] } },
});
check("assistant 摘要正文不含 reasoning 块文本", reasoningMessage.data?.text === "VISIBLE-BODY", JSON.stringify(reasoningMessage.data?.text));
check("assistant 摘要仍单独下发 reasoning 供折叠块", reasoningMessage.data?.reasoning === "THINKING-CHAIN");
check("详情指针带未截断正文长度提示", reasoningMessage.detail?.textChars === "VISIBLE-BODY".length, String(reasoningMessage.detail?.textChars));
check("无 content 的 assistant 事件不给长度提示", mod.summarizeEvent({ seq: 13, type: "assistant/message", data: { turn: 1 } }).detail?.textChars === undefined);
check("非 assistant 事件不给长度提示", visibleCall.detail?.textChars === undefined);

const assistantDetail = mod.detailEventFor({
  seq: 12,
  type: "assistant/message",
  data: { turn: 1, message: { id: "m1", content: [
    { type: "reasoning", text: "THINKING-CHAIN" },
    { type: "text", text: "VISIBLE-BODY" },
  ] } },
});
check("详情规范化正文不含 reasoning 块文本", assistantDetail.data?.text === "VISIBLE-BODY", JSON.stringify(assistantDetail.data?.text));
check("详情保留原始 message 块（无损语义）", assistantDetail.data?.message?.content?.length === 2);
check("详情规范化正文与指针提示同口径", assistantDetail.data?.text?.length === reasoningMessage.detail?.textChars);
check("详情不改写其它类型事件的 data", mod.detailEventFor({ seq: 22, type: "tool/result", data: { text: "raw" } }).data?.text === "raw");
const liveChunk = mod.summarizeEvent({
  seq: 10,
  type: "assistant/live-chunk",
  data: { turn: 1, step: 2, chunk: { type: "tool-call-delta", id: "call-2", name: "shell", argumentsDelta: "ls" } },
});
check("assistant/live-chunk 与普通 chunk 同形摘要", liveChunk.data?.callId === "call-2" && mod.isLiveTimelineRecord(liveChunk));
const directToolResult = mod.summarizeEvent({
  seq: 10,
  type: "tool/result",
  data: {
    callId: "call-1",
    name: "read_file",
    text: "direct result",
    isError: false,
    images: [{ attachmentId: "att-1", mediaType: "image/png", width: 10, height: 20, data: "SHOULD-DROP" }, { data: "invalid" }],
     files: [{ path: "/tmp/report.md", name: "report.md", mediaType: "text/markdown", size: 42, data: "SHOULD-DROP" }],
  },
});
check("直接形态工具结果保留 identity/text", directToolResult.data?.callId === "call-1" && directToolResult.data?.name === "read_file" && directToolResult.data?.text === "direct result");
check("直接形态图片只保留 metadata", directToolResult.data?.images?.length === 1 && directToolResult.data.images[0].attachmentId === "att-1" && directToolResult.data.images[0].data === undefined);
check("tool/result 不再下发文件元数据（issue #1 需求变更）", directToolResult.data?.files === undefined, JSON.stringify(directToolResult.data?.files));

// issue #1 需求变更：产出文件（tool/result / assistant/message）停发 files；用户自己的附件保留
const assistantWithFile = mod.summarizeEvent({
  seq: 21,
  type: "assistant/message",
  data: { turn: 1, step: 1, message: { id: "a1", content: [
    { type: "text", text: "写好了" },
    { type: "file", path: "/tmp/out.md", name: "out.md" },
  ] } },
});
check("assistant/message 不再下发文件元数据", assistantWithFile.data?.files === undefined, JSON.stringify(assistantWithFile.data?.files));
const userWithFile = mod.summarizeEvent({
  seq: 22,
  type: "user/message",
  data: { id: "u1", content: [
    { type: "text", text: "看这个" },
    { type: "file", path: "/tmp/a.md", name: "a.md" },
  ] },
});
check("user/message 仍下发附件元数据", userWithFile.data?.files?.length === 1 && userWithFile.data.files[0].name === "a.md", JSON.stringify(userWithFile.data?.files));

// 最小真实路由 harness：验证 bootstrap/history/event-detail 走同一鉴权/路由入口，
// 同时覆盖 active session 与 session-query 的 dormant fallback。
if (typeof mod.apply === "function" && typeof mod.Config === "function") {
  const routes = [];
  const hooks = new Map();
  const wireWarnings = [];
  const events = [
    { seq: 0, type: "request/header", data: { systemPrompt: "SECRET", toolSchema: "SECRET" } },
    { seq: 1, type: "user/message", data: { text: "inspect" } },
    { seq: 2, type: "tool/result", time: 123, customMeta: { lineage: "keep" }, data: { callId: "call-1", text: "full raw result", isError: false } },
    { seq: 3, type: "future/visible", ignorable: true, data: { nested: { value: 42 } } },
    { seq: 4, type: "assistant/chunk", data: { chunk: { type: "text-delta", text: "transient" } } },
    { seq: 5, type: "system/message", data: { systemPrompt: "SECRET-2" } },
    ...Array.from({ length: 12 }, (_, index) => ({ seq: 6 + index, type: "future/page", data: { index } })),
    { seq: 18, type: "assistant/attempt", data: { turn: 1, step: 1, stream: [{ text: "RAW-STREAM" }] } },
    { seq: 19, type: "compaction/summary", data: { summary: [{ text: "SNAPSHOT-SECRET" }], shadowedSeqs: [1, 2] } },
    { seq: 20, type: "compaction/start", data: { compactionId: "cmp-1" } },
    // PR #24 复核：内核真实存在的两类 LLM 请求快照（system prompt + 对话正文 + route）。
    { seq: 21, type: "session/title-llm-request", data: { titleProvider: "deepseek", route: "/v1/chat", system: "SYSTEM-PROMPT-SECRET", messages: [{ text: "CONVERSATION-BODY" }], maxTokens: 64 } },
    { seq: 22, type: "web/deepseek-search-llm-request", data: { endpoint: "https://api.example/v1", apiVersion: "2023-06-01", body: { system: "SEARCH-SYSTEM-SECRET" }, hostPath: "C:\\Users\\mark\\secret" } },
    // 未命名/未知可见事件：带敏感夹具，验证详情端点 fail-closed 而不是 200 泄露。
    { seq: 23, type: "request/something-new", data: { systemPrompt: "UNNAMED-SYSTEM-SECRET", messages: [{ text: "UNNAMED-BODY" }] } },
  ];
  const hugeText = "A".repeat(8 * 1024 * 1024 + 1024);
  const huge = { id: "session-huge", header: { createdAt: 1, cwd: "/tmp" }, events: [{ seq: 1, type: "tool/result", data: { callId: "call-huge", text: hugeText } }], snapshotEvents() { return this.events; } };
  const active = { id: "session-1", header: { createdAt: 1, cwd: "/tmp" }, events, snapshotEvents() { return this.events; } };
  const activeReadError = { id: "session-active-read-error", header: { createdAt: 1, cwd: "/tmp" }, events: [], snapshotEvents() { return this.events; } };
  const sessions = new Map([[active.id, active], [activeReadError.id, activeReadError], [huge.id, huge]]);
  const dormant = [{ seq: 8, type: "tool/result", data: { dormant: true, callId: "call-dormant", text: "dormant raw result" } }];
  const dormantUnlisted = [{ seq: 8, type: "future/dormant-unlisted", data: { secret: "DORMANT-SECRET" } }];
  const seededSurface = [{ seq: 8, type: "tool/result", data: { recovered: true, callId: "call-surface", text: "surface raw result" } }];
  const services = {
    sessions: { get: (id) => sessions.get(id), list: () => [...sessions.values()] },
    agents: {
      get: (id) => (id === active.id ? { session: active } : undefined),
      list: () => [{ id: "session:session-1", status: "running", session: active, inbox: { hasPending: false } }],
    },
    sessionQuery: {
      async readSession(id) {
        if (id === "session-read-error" || id === "session-fallback-error") throw new Error("sensitive host path /home/mark/private/session.zstd");
        if (id !== "session-dormant") throw new Error("not dormant");
        return { events: dormant };
      },
      async readEvent({ sessionId, seq }) {
        if (sessionId === "session-dormant" && seq === 8) return { session: { id: "session-dormant" }, target: dormant[0], events: [dormant[0]] };
        if (sessionId === "session-dormant-unlisted" && seq === 8) return { session: { id: "session-dormant-unlisted" }, target: dormantUnlisted[0], events: [dormantUnlisted[0]] };
        if (sessionId === "session-wrong" && seq === 8) return { session: { id: "other-session" }, target: dormant[0], events: [dormant[0]] };
        if (sessionId === "session-read-error" || sessionId === "session-active-read-error") throw new Error("sensitive host path /home/mark/private/session.zstd");
        if (sessionId === "session-missing") throw Object.assign(new Error("missing storage path"), { code: "SESSION_QUERY_SESSION_NOT_FOUND" });
        if (sessionId === "session-corrupt") throw Object.assign(new Error("corrupt storage path /private/session.zstd"), { code: "SESSION_QUERY_CORRUPT_SESSION" });
        if (sessionId === "session-fallback-error") return null;
        if (sessionId === "session-seeded" || sessionId === "session-seeded-missing") {
          throw new Error("seeded session constructor seed must equal its inherited prefix");
        }
        throw new Error("not indexed");
      },
      async readSurface(id) {
        if (id === "session-seeded") return { events: seededSurface };
        if (id === "session-seeded-missing") return { events: [{ seq: 9, type: "future/other", data: {} }] };
        throw new Error("surface unavailable");
      },
    },
  };
  const ctx = {
    logger: { info() {}, warn(...args) { wireWarnings.push(args.join(' ')); }, error() {}, debug() {} },
    get(name) { return services[name]; },
    on(event, fn) { hooks.set(event, fn); return () => hooks.delete(event); },
    effect(fn) { return fn(); },
    inject() {},
    provide() {},
    waterfall: async (_name, _args, next) => next(),
    webServer: { host: "127.0.0.1", port: 3080, register(route) { routes.push(route); return () => {}; } },
  };
  try {
    mod.apply(ctx, mod.Config({ path: "/m", authToken: "secret-secret-secret-1234", pushUrls: [], lanBridge: { enabled: false } }));
    const route = routes.find((r) => r.path === "/m/api");
    const request = (url, { token = "secret-secret-secret-1234", host = "127.0.0.1:3080", remoteAddress = "127.0.0.1", method = "GET" } = {}) => ({
      url,
      method,
      headers: { host, ...(token === null ? {} : { "x-mobile-token": token }) },
      socket: { remoteAddress },
      on() { return this; },
      pause() {},
      resume() {},
    });
    const response = () => {
      const chunks = [];
      return {
        statusCode: 0,
        headersSent: false,
        ended: false,
        writeHead(status) { this.statusCode = status; this.headersSent = true; },
        setHeader() {},
        write(chunk) { chunks.push(String(chunk)); return true; },
        end(chunk) { if (chunk !== undefined) chunks.push(String(chunk)); this.ended = true; },
        destroy() { this.ended = true; },
        on() { return this; },
        get text() { return chunks.join(""); },
        get json() { try { return JSON.parse(chunks.join("")); } catch { return null; } },
      };
    };
    const call = async (url, options = {}) => {
      const res = response();
      route?.handler(request(url, options), res);
      for (let i = 0; i < 50 && !res.ended; i++) await new Promise((resolve) => setTimeout(resolve, 2));
      return res;
    };
    // 大载荷用例（8 MiB+ JSON 校验）需要更宽的就绪等待预算。
    const callSlow = async (url, options = {}, attempts = 600) => {
      const res = response();
      route?.handler(request(url, options), res);
      for (let i = 0; i < attempts && !res.ended; i++) await new Promise((resolve) => setTimeout(resolve, 5));
      return res;
    };
    const unauthorized = await call("/m/api/bootstrap", { token: null });
    check("缺 token 返回 401", unauthorized.statusCode === 401 && unauthorized.json?.error === "auth-required", JSON.stringify(unauthorized.json));
    const wrongToken = await call("/m/api/bootstrap", { token: "wrong" });
    check("错误 token 返回 401", wrongToken.statusCode === 401 && wrongToken.json?.error === "auth-required", JSON.stringify(wrongToken.json));
    const wrongHost = await call("/m/api/bootstrap", { host: "evil.example:3080" });
    check("非法 Host 返回 403", wrongHost.statusCode === 403 && wrongHost.json?.error === "host-not-allowed", JSON.stringify(wrongHost.json));
    const bootstrap = await call("/m/api/bootstrap");
    check("bootstrap 宣布 eventTimeline capability", bootstrap.json?.capabilities?.eventTimeline?.detail === true, `${bootstrap.json?.error ?? ''} ${wireWarnings.at(-1) ?? ''}`);
    check("bootstrap 下发 agentId→sessionId 映射", bootstrap.json?.agents?.[0]?.sessionId === "session-1" && bootstrap.json.agents[0].id === "session:session-1", JSON.stringify(bootstrap.json?.agents));
    const history = await call("/m/api/history?sessionId=session-1&after=0&limit=10");
    check("history 保留未知事件并过滤内部/chunk", history.json?.events?.some((e) => e.type === "future/visible") === true && !history.json?.events?.some((e) => ["assistant/chunk", "request/header", "system/message"].includes(e.type)), `${history.json?.error ?? ''} ${wireWarnings.at(-1) ?? ''}`);
    check("history 返回 hasMore/cursor", history.json?.hasMore === true && history.json?.after === history.json?.events?.at(-1)?.seq, `${JSON.stringify(history.json)} ${wireWarnings.at(-1) ?? ''}`);
    const fullHistory = await call("/m/api/history?sessionId=session-1&limit=1000");
    check(
      "history 不返回重建/压缩快照",
      ["assistant/attempt", "compaction/start", "compaction/summary", "compaction/prune"].every((type) => !fullHistory.json?.events?.some((e) => e.type === type)),
      JSON.stringify(fullHistory.json?.events?.map((e) => e.type)),
    );
    const snapshotDetail = await call("/m/api/event-detail?sessionId=session-1&seq=19");
    check("event-detail 不泄露压缩摘要快照", snapshotDetail.statusCode === 404 && snapshotDetail.json?.error === "event-not-found", JSON.stringify(snapshotDetail.json));
    // PR #24 复核（阻断级泄露）：LLM 请求快照既不出现在 history，也不能经详情端点取回。
    check(
      "history 不返回 LLM 请求快照",
      !fullHistory.json?.events?.some((e) => e.type.includes("llm-request")),
      JSON.stringify(fullHistory.json?.events?.map((e) => e.type)),
    );
    const titleRequestSummary = fullHistory.json?.events?.find((e) => e.type === "session/title-llm-request");
    check("LLM 请求快照不出现在任何摘要里", titleRequestSummary === undefined, JSON.stringify(titleRequestSummary));
    const titleRequestDetail = await call("/m/api/event-detail?sessionId=session-1&seq=21");
    check(
      "event-detail 不泄露标题 LLM 请求快照（system prompt/messages）",
      titleRequestDetail.statusCode === 404
        && titleRequestDetail.json?.error === "event-not-found"
        && !JSON.stringify(titleRequestDetail.json).includes("SYSTEM-PROMPT-SECRET"),
      JSON.stringify(titleRequestDetail.json),
    );
    const searchRequestDetail = await call("/m/api/event-detail?sessionId=session-1&seq=22");
    check(
      "event-detail 不泄露 web 搜索 LLM 请求快照",
      searchRequestDetail.statusCode === 404
        && searchRequestDetail.json?.error === "event-not-found"
        && !JSON.stringify(searchRequestDetail.json).includes("SEARCH-SYSTEM-SECRET")
        && !JSON.stringify(searchRequestDetail.json).includes("mark"),
      JSON.stringify(searchRequestDetail.json),
    );
    // fail-closed：未命名/未知可见事件仍保留在 history（事件保真契约），但不再给详情指针。
    const unlistedSummary = fullHistory.json?.events?.find((e) => e.type === "request/something-new");
    check(
      "未知可见事件仍保留在 history",
      unlistedSummary !== undefined && unlistedSummary.seq === 23 && unlistedSummary.data === undefined,
      JSON.stringify(unlistedSummary),
    );
    check("未知可见事件不再声明详情指针", unlistedSummary?.detail === undefined, JSON.stringify(unlistedSummary?.detail));
    const unlistedDetail = await call("/m/api/event-detail?sessionId=session-1&seq=23");
    check(
      "event-detail 对未列入 allow-list 的未知类型 fail-closed（404，非 200 泄露）",
      unlistedDetail.statusCode === 404
        && unlistedDetail.json?.error === "event-not-found"
        && !JSON.stringify(unlistedDetail.json).includes("UNNAMED-SYSTEM-SECRET"),
      JSON.stringify(unlistedDetail.json),
    );
    const badAfter = await call("/m/api/history?sessionId=session-1&after=12junk");
    check("history 校验 malformed after", badAfter.statusCode === 400 && badAfter.json?.error === "bad-request", JSON.stringify(badAfter.json));
    const emptyBefore = await call("/m/api/history?sessionId=session-1&before=");
    check("history 校验 empty before", emptyBefore.statusCode === 400 && emptyBefore.json?.error === "bad-request", JSON.stringify(emptyBefore.json));
    const malformedBefore = await call("/m/api/history?sessionId=session-1&before=12junk");
    check("history 校验 malformed before", malformedBefore.statusCode === 400 && malformedBefore.json?.error === "bad-request", JSON.stringify(malformedBefore.json));
    const detail = await call("/m/api/event-detail?sessionId=session-1&seq=2");
    check("active event-detail 返回无损 data/metadata", detail.json?.event?.data?.text === "full raw result" && detail.json?.event?.time === 123 && detail.json?.event?.customMeta?.lineage === "keep", `${detail.json?.error ?? ''} ${wireWarnings.at(-1) ?? ''}`);
    const hiddenDetail = await call("/m/api/event-detail?sessionId=session-1&seq=0");
    check("event-detail 不泄露 request/header", hiddenDetail.statusCode === 404 && hiddenDetail.json?.error === "event-not-found", JSON.stringify(hiddenDetail.json));
    const dormantDetail = await call("/m/api/event-detail?sessionId=session-dormant&seq=8");
    check("dormant event-detail 使用 sessionQuery", dormantDetail.json?.event?.data?.dormant === true, `${dormantDetail.json?.error ?? ''} ${wireWarnings.at(-1) ?? ''}`);
    const dormantUnlistedDetail = await call("/m/api/event-detail?sessionId=session-dormant-unlisted&seq=8");
    check(
      "event-detail 在 sessionQuery 路径同样 fail-closed",
      dormantUnlistedDetail.statusCode === 404
        && dormantUnlistedDetail.json?.error === "event-not-found"
        && !JSON.stringify(dormantUnlistedDetail.json).includes("DORMANT-SECRET"),
      JSON.stringify(dormantUnlistedDetail.json),
    );
    const readFailureDetail = await call("/m/api/event-detail?sessionId=session-read-error&seq=8");
    check(
      "event-detail 读取异常返回稳定 500 且不泄露原始错误",
      readFailureDetail.statusCode === 500
        && readFailureDetail.json?.error === "event-read-failed"
        && !JSON.stringify(readFailureDetail.json).includes("/home/mark/private"),
      JSON.stringify(readFailureDetail.json),
    );
    const activeReadFailureDetail = await call("/m/api/event-detail?sessionId=session-active-read-error&seq=8");
     check(
       "event-detail 活动会话读取异常不被快照回退伪装",
       activeReadFailureDetail.statusCode === 500
         && activeReadFailureDetail.json?.error === "event-read-failed"
         && !JSON.stringify(activeReadFailureDetail.json).includes("/home/mark/private"),
       JSON.stringify(activeReadFailureDetail.json),
     );
     const missingSessionDetail = await call("/m/api/event-detail?sessionId=session-missing&seq=8");
    check(
      "event-detail 仅把明确不存在映射为 session-not-found",
      missingSessionDetail.statusCode === 404 && missingSessionDetail.json?.error === "session-not-found",
      JSON.stringify(missingSessionDetail.json),
    );
    const corruptSessionDetail = await call("/m/api/event-detail?sessionId=session-corrupt&seq=8");
    check(
      "event-detail 区分会话损坏且不泄露原始错误",
      corruptSessionDetail.statusCode === 500
        && corruptSessionDetail.json?.error === "session-corrupt"
        && !JSON.stringify(corruptSessionDetail.json).includes("/private/session.zstd"),
      JSON.stringify(corruptSessionDetail.json),
    );
    const seededDetail = await call("/m/api/event-detail?sessionId=session-seeded&seq=8");
    check(
      "event-detail seeded 缺陷降级读取 current surface 并显式标记",
      seededDetail.statusCode === 200
        && seededDetail.json?.event?.data?.recovered === true
        && seededDetail.json?.degraded === true
        && seededDetail.json?.detailMode === "current-surface",
      JSON.stringify(seededDetail.json),
    );
    const seededMissingDetail = await call("/m/api/event-detail?sessionId=session-seeded-missing&seq=8");
    check(
      "event-detail current surface 未命中时返回 event-not-found",
      seededMissingDetail.statusCode === 404 && seededMissingDetail.json?.error === "event-not-found",
      JSON.stringify(seededMissingDetail.json),
    );
    const fallbackFailureDetail = await call("/m/api/event-detail?sessionId=session-fallback-error&seq=8");
    check(
      "event-detail 快照回退异常不伪装成 session-not-found",
      fallbackFailureDetail.statusCode === 500
        && fallbackFailureDetail.json?.error === "event-read-failed"
        && !JSON.stringify(fallbackFailureDetail.json).includes("/home/mark/private"),
      JSON.stringify(fallbackFailureDetail.json),
    );
    const wrongSessionDetail = await call("/m/api/event-detail?sessionId=session-wrong&seq=8");
    check("event-detail 校验 query session identity", wrongSessionDetail.statusCode === 404, JSON.stringify(wrongSessionDetail.json));
    // 8 MiB 上限（PR #24 复核补测）：allow-list 内的大事件仍受体积上限保护，返回 413。
    const hugeDetail = await callSlow("/m/api/event-detail?sessionId=session-huge&seq=1");
    check(
      "event-detail 超过 8 MiB 返回 413 event-detail-too-large",
      hugeDetail.statusCode === 413 && hugeDetail.json?.error === "event-detail-too-large",
      `${hugeDetail.statusCode} ${JSON.stringify(hugeDetail.json)} ${wireWarnings.at(-1) ?? ''}`,
    );
    const badDetail = await call("/m/api/event-detail?sessionId=session-1&seq=not-a-number");
    check("event-detail 校验 seq", badDetail.statusCode === 400 && badDetail.json?.error === "bad-request", JSON.stringify(badDetail.json));
    const emptyDetail = await call("/m/api/event-detail?sessionId=session-1&seq=");
    check("event-detail 校验 empty seq", emptyDetail.statusCode === 400 && emptyDetail.json?.error === "bad-request", JSON.stringify(emptyDetail.json));
    const negativeZeroDetail = await call("/m/api/event-detail?sessionId=session-1&seq=-0");
    check("event-detail 拒绝 -0", negativeZeroDetail.statusCode === 400 && negativeZeroDetail.json?.error === "bad-request", JSON.stringify(negativeZeroDetail.json));
    const qrRemote = await call("/m/api/qr-config", { remoteAddress: "192.168.1.20" });
    check("qr-config 非回环返回 403", qrRemote.statusCode === 403 && qrRemote.json?.error === "loopback-only", JSON.stringify(qrRemote.json));
    const sse = response();
    route?.handler(request("/m/api/events"), sse);
    await new Promise((resolve) => setTimeout(resolve, 15));
    check("SSE hello 宣布 eventTimeline capability", sse.text.includes('"eventTimeline"') && sse.text.includes('"detail":true'), sse.text.slice(0, 300));
    const sessionEvent = hooks.get("session/event");
    sessionEvent?.(active, { seq: 30, type: "future/live", data: { visible: true } });
    sessionEvent?.(active, { seq: 31, type: "request/header", data: { systemPrompt: "SECRET" } });
    await new Promise((resolve) => setTimeout(resolve, 5));
    check("live/history 同步过滤内部但保留未知", sse.text.includes('"future/live"') && !sse.text.includes('"systemPrompt":"SECRET"'), sse.text.slice(-800));
  } catch (error) {
    check("wire harness 可启动真实路由", false, error?.stack ?? String(error));
  }
} else {
  check("wire harness exports apply/Config", false, "module exports missing");
}

console.log(`结果：${pass} PASS / ${fail} FAIL`);
if (fail > 0) process.exit(1);
