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

// v3.1.5 修复：结果事件缺工具名时**不得用 callId 兜底**。callId 是关联 id，不是工具名；
// 旧行为让 App 合并规则把 `tool/call` 学到的真名覆盖成裸 `call_00_...`，历史回放的
// 工具卡标题因此错成 id（进行中的那张正常）。
const namelessToolResult = mod.summarizeEvent({
  seq: 11,
  type: "tool/result",
  data: { callId: "call-nameless", text: "result without a tool name", isError: false },
});
check(
  "tool/result 缺工具名时不下发 name（绝不用 callId 兜底）",
  namelessToolResult.data?.name === undefined && namelessToolResult.data?.callId === "call-nameless",
  `name=${JSON.stringify(namelessToolResult.data?.name)}`,
);
const erroredToolResult = mod.summarizeEvent({
  seq: 12,
  type: "tool/result",
  data: { callId: "call-errored", error: { name: "UserQuestionError", message: "cancelled" }, text: "" },
});
check(
  "tool/result 的错误名仍是有效工具名（不误伤 UserQuestionError）",
  erroredToolResult.data?.name === "UserQuestionError",
  `name=${JSON.stringify(erroredToolResult.data?.name)}`,
);

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
  const outlineObserved = [];
  const outlineDisposed = [];
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
      // issue #25 二期：投影感知观察面。宿主真实接口是
      // `sessionQuery.observeSession(id, { projectionMode, signal })`，返回带 `.projections`
      // （`{ asOfSeq, values }`）的 lease；App 侧刻度轨消费的正是 values.turnOutline。
      async observeSession(id, options = {}) {
        outlineObserved.push({ id, projectionMode: options.projectionMode, hasSignal: options.signal !== undefined });
        const leaseOf = (projections) => ({
          projections,
          [Symbol.dispose]() { outlineDisposed.push(id); },
        });
        const outlineTurns = [
          { turn: 1, seq: 0, prompt: "第一轮提示", response: "第一轮回复" },
          { turn: 2, seq: 12, prompt: "", response: "纯命令轮的回复" },
          { turn: 3, seq: 40, prompt: "第三轮提示", response: "" },
        ];
        if (id === "session-outline-ok") return leaseOf({ asOfSeq: 40, values: { turnOutline: outlineTurns } });
        if (id === "session-outline-empty") return leaseOf({ asOfSeq: 3, values: { turnOutline: [] } });
        if (id === "session-outline-no-unit") return leaseOf({ asOfSeq: 3, values: { title: "只有别的投影" } });
        if (id === "session-outline-no-snapshot") return leaseOf(undefined);
        if (id === "session-outline-huge") {
          return leaseOf({
            asOfSeq: 99_999,
            values: { turnOutline: Array.from({ length: 3000 }, (_, index) => ({ turn: index + 1, seq: index, prompt: "P".repeat(50), response: "R".repeat(120) })) },
          });
        }
        if (id === "session-outline-timeout") throw Object.assign(new Error("bounded wait expired"), { name: "TimeoutError" });
        // 宿主可能把超时的 reason 包进 SessionQueryError.cause：必须仍识别为"超时"，
        // 而不是按外层 code 误报成"会话损坏"。
        if (id === "session-outline-timeout-wrapped") {
          throw Object.assign(new Error("failed to observe session"), {
            code: "SESSION_QUERY_CORRUPT_SESSION",
            cause: Object.assign(new Error("bounded wait expired"), { name: "TimeoutError" }),
          });
        }
        if (id === "session-outline-seeded") throw new Error("seeded session constructor seed must equal its inherited prefix");
        // 真实宿主形状（issue #25 评审 P2）：observeSession 把 seeded 前缀缺陷包进
        // SessionQueryError(code=SESSION_QUERY_CORRUPT_SESSION, cause=seeded Error)。
        // 通用分类若先判 corrupt，稳定降级就到不了这个分支。
        if (id === "session-outline-seeded-wrapped") {
          throw Object.assign(new Error("stored session is corrupt"), {
            code: "SESSION_QUERY_CORRUPT_SESSION",
            cause: new Error("seeded session constructor seed must equal its inherited prefix"),
          });
        }
        if (id === "session-outline-corrupt") throw Object.assign(new Error("corrupt storage /private/session.zstd"), { code: "SESSION_QUERY_CORRUPT_SESSION" });
        if (id === "session-outline-missing") throw Object.assign(new Error("missing storage path"), { code: "SESSION_QUERY_SESSION_NOT_FOUND" });
        throw new Error("outline unavailable");
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
    // issue #25 二期：轮次大纲能力位。宿主没挂投影时必须显式说"不支持"——App 据此退回一期行为，
    // 不允许按宿主版本自行推断，也不允许把"能力缺失"与"该会话无大纲"混为一谈。
    check(
      "bootstrap 在宿主未挂投影服务时声明 supported=false",
      bootstrap.json?.capabilities?.turnOutline?.supported === false,
      JSON.stringify(bootstrap.json?.capabilities?.turnOutline),
    );
    // issue #25 评审 P2：**只有投影服务存在**不算支持——必须验证 `turnOutline` 单元真的注册，
    // 且观察接口可用；否则会出现"声明支持、端点却回 capability-missing"的矛盾。
    services.sessionProjections = {};
    const bootstrapServiceOnly = await call("/m/api/bootstrap");
    check(
      "bootstrap 只有投影服务、没有该单元 → supported=false",
      bootstrapServiceOnly.json?.capabilities?.turnOutline?.supported === false,
      JSON.stringify(bootstrapServiceOnly.json?.capabilities?.turnOutline),
    );
    services.sessionProjections = { registrations: new Map() };
    const bootstrapNoUnit = await call("/m/api/bootstrap");
    check(
      "bootstrap registry 存在但零单元 → supported=false",
      bootstrapNoUnit.json?.capabilities?.turnOutline?.supported === false,
      JSON.stringify(bootstrapNoUnit.json?.capabilities?.turnOutline),
    );
    services.sessionProjections = { registrations: new Map([["turnOutline", {}]]) };
    const savedObserve = services.sessionQuery.observeSession;
    delete services.sessionQuery.observeSession;
    const bootstrapNoObservable = await call("/m/api/bootstrap");
    check(
      "bootstrap 单元已注册但观察接口缺失 → supported=false",
      bootstrapNoObservable.json?.capabilities?.turnOutline?.supported === false,
      JSON.stringify(bootstrapNoObservable.json?.capabilities?.turnOutline),
    );
    services.sessionQuery.observeSession = savedObserve;
    const bootstrapOutline = await call("/m/api/bootstrap");
    check(
      "bootstrap 单元注册且观察接口可用时声明 turnOutline 能力（unloaded/truncated）",
      bootstrapOutline.json?.capabilities?.turnOutline?.supported === true
        && bootstrapOutline.json.capabilities.turnOutline.unloaded === true
        && bootstrapOutline.json.capabilities.turnOutline.truncated === true,
      JSON.stringify(bootstrapOutline.json?.capabilities?.turnOutline),
    );
    // /turn-outline：只读契约。三态（能力缺失 / 该会话无大纲 / 可用）+ 读取失败态必须可区分。
    const outlineUnauthorized = await call("/m/api/turn-outline?sessionId=session-outline-ok", { token: null });
    check("turn-outline 缺 token 返回 401", outlineUnauthorized.statusCode === 401 && outlineUnauthorized.json?.error === "auth-required", JSON.stringify(outlineUnauthorized.json));
    const outlineWrongHost = await call("/m/api/turn-outline?sessionId=session-outline-ok", { host: "evil.example:3080" });
    check("turn-outline 非法 Host 返回 403", outlineWrongHost.statusCode === 403 && outlineWrongHost.json?.error === "host-not-allowed", JSON.stringify(outlineWrongHost.json));
    const outlinePost = await call("/m/api/turn-outline?sessionId=session-outline-ok", { method: "POST" });
    check("turn-outline 只接受 GET", outlinePost.statusCode === 405 && outlinePost.json?.error === "method-not-allowed", JSON.stringify(outlinePost.json));
    const outlineNoSession = await call("/m/api/turn-outline");
    check("turn-outline 缺 sessionId 返回 400", outlineNoSession.statusCode === 400 && outlineNoSession.json?.error === "bad-request", JSON.stringify(outlineNoSession.json));
    const outlineOk = await call("/m/api/turn-outline?sessionId=session-outline-ok");
    check(
      "turn-outline 可用态：轮次升序、字段齐备、asOfSeq 透出",
      outlineOk.json?.state === "available"
        && outlineOk.json.turns?.length === 3
        && outlineOk.json.turns.map((t) => t.turn).join(",") === "1,2,3"
        && outlineOk.json.turns.every((t) => typeof t.seq === "number" && typeof t.prompt === "string" && typeof t.response === "string")
        && outlineOk.json.asOfSeq === 40,
      `${outlineOk.json?.error ?? ''} ${JSON.stringify(outlineOk.json)}`,
    );
    check(
      "turn-outline 空提示词/空回复原样下发（App 侧回退「第 N 轮」）",
      outlineOk.json?.turns?.[1]?.prompt === "" && outlineOk.json?.turns?.[2]?.response === "",
      JSON.stringify(outlineOk.json?.turns),
    );
    check(
      "turn-outline 走投影感知观察面（projectionMode=all + 有界 signal）",
      outlineObserved.at(-1)?.id === "session-outline-ok"
        && outlineObserved.at(-1)?.projectionMode === "all"
        && outlineObserved.at(-1)?.hasSignal === true,
      JSON.stringify(outlineObserved.at(-1)),
    );
    check("turn-outline 释放观察 lease（不泄漏 prepared 会话 pin）", outlineDisposed.includes("session-outline-ok"), JSON.stringify(outlineDisposed));
    const outlineEmpty = await call("/m/api/turn-outline?sessionId=session-outline-empty");
    check(
      "turn-outline 该会话无大纲 → state=empty（与能力缺失区分，不靠空数组推断）",
      outlineEmpty.statusCode === 200 && outlineEmpty.json?.state === "empty" && Array.isArray(outlineEmpty.json.turns) && outlineEmpty.json.turns.length === 0,
      JSON.stringify(outlineEmpty.json),
    );
    const outlineNoUnit = await call("/m/api/turn-outline?sessionId=session-outline-no-unit");
    check("turn-outline 投影单元未注册 → state=capability-missing", outlineNoUnit.json?.state === "capability-missing", JSON.stringify(outlineNoUnit.json));
    const outlineNoSnapshot = await call("/m/api/turn-outline?sessionId=session-outline-no-snapshot");
    check("turn-outline 观察面没有投影快照 → state=capability-missing", outlineNoSnapshot.json?.state === "capability-missing", JSON.stringify(outlineNoSnapshot.json));
    const outlineHuge = await callSlow("/m/api/turn-outline?sessionId=session-outline-huge");
    check(
      "turn-outline 超体积上限只回最近 N 轮并显式标 truncated/dropped",
      outlineHuge.json?.state === "available"
        && outlineHuge.json.truncated === true
        && outlineHuge.json.dropped > 0
        && outlineHuge.json.turns.length < 3000
        && outlineHuge.json.turns.at(-1).turn === 3000
        && outlineHuge.json.turns[0].turn === 3000 - outlineHuge.json.turns.length + 1
        && Buffer.byteLength(JSON.stringify(outlineHuge.json.turns)) <= 256 * 1024 + 64,
      `${outlineHuge.statusCode} turns=${outlineHuge.json?.turns?.length} dropped=${outlineHuge.json?.dropped}`,
    );
    const outlineTimeout = await call("/m/api/turn-outline?sessionId=session-outline-timeout");
    check(
      "turn-outline 有界等待超时 → 明确降级结果（不静默、不无限等待）",
      outlineTimeout.statusCode === 200
        && outlineTimeout.json?.state === "read-failed"
        && outlineTimeout.json.code === "turn-outline-timeout"
        && outlineTimeout.json.degraded === true,
      JSON.stringify(outlineTimeout.json),
    );
    const outlineTimeoutWrapped = await call("/m/api/turn-outline?sessionId=session-outline-timeout-wrapped");
    check(
      "turn-outline 超时被包进 cause 链时仍识别为超时（不误报会话损坏）",
      outlineTimeoutWrapped.statusCode === 200
        && outlineTimeoutWrapped.json?.code === "turn-outline-timeout"
        && outlineTimeoutWrapped.json.state === "read-failed",
      JSON.stringify(outlineTimeoutWrapped.json),
    );
    const outlineSeeded = await call("/m/api/turn-outline?sessionId=session-outline-seeded");
    check(
      "turn-outline seeded 核心缺陷 → 显式降级而非 500",
      outlineSeeded.statusCode === 200
        && outlineSeeded.json?.state === "read-failed"
        && outlineSeeded.json.code === "turn-outline-unavailable"
        && outlineSeeded.json.degraded === true,
      JSON.stringify(outlineSeeded.json),
    );
    const outlineCorrupt = await call("/m/api/turn-outline?sessionId=session-outline-corrupt");
    check(
      "turn-outline 会话损坏 → 稳定 500 session-corrupt 且不泄露原始错误",
      outlineCorrupt.statusCode === 500
        && outlineCorrupt.json?.error === "session-corrupt"
        && !JSON.stringify(outlineCorrupt.json).includes("/private/session.zstd"),
      JSON.stringify(outlineCorrupt.json),
    );
    const outlineSeededWrapped = await call("/m/api/turn-outline?sessionId=session-outline-seeded-wrapped");
    check(
      "turn-outline seeded 缺陷被包进 corrupt cause 链时仍走稳定降级（不误报损坏）",
      outlineSeededWrapped.statusCode === 200
        && outlineSeededWrapped.json?.state === "read-failed"
        && outlineSeededWrapped.json.code === "turn-outline-unavailable"
        && outlineSeededWrapped.json.degraded === true,
      JSON.stringify(outlineSeededWrapped.json),
    );
    const outlineMissing = await call("/m/api/turn-outline?sessionId=session-outline-missing");
    check(
      "turn-outline 明确不存在 → 404 session-not-found（只有这一种才 404）",
      outlineMissing.statusCode === 404 && outlineMissing.json?.error === "session-not-found",
      JSON.stringify(outlineMissing.json),
    );
    // 纯函数：截断按体积而不是轮数（12 轮的会话也可能只有 3 KB），且至少保留 1 轮。
    check(
      "clampTurnOutline 按体积从最新往回截断且至少保留 1 轮",
      mod.clampTurnOutline(Array.from({ length: 100 }, (_, i) => ({ turn: i + 1, seq: i, prompt: "p".repeat(20), response: "r".repeat(20) })), 0).turns.length === 1
        && mod.clampTurnOutline([{ turn: 1 }], 10).truncated === false,
      JSON.stringify(mod.clampTurnOutline([{ turn: 1 }], 0)),
    );
    // issue #25 评审 P1：有界执行槽——队列有上限、并发为 1、排队期间已超时的任务不执行。
    if (typeof mod.createTurnOutlineQueue === "function") {
      const queue = mod.createTurnOutlineQueue({ maxQueue: 1 });
      let releaseFirst;
      const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
      const order = [];
      const first = queue.run(async () => { order.push("first-start"); await firstGate; order.push("first-end"); return "a"; });
      const second = queue.run(async () => { order.push("second"); return "b"; });
      let busyError;
      const third = queue.run(async () => "c").catch((error) => { busyError = error; });
      await new Promise((resolve) => setTimeout(resolve, 0));
      check("有界队列：满时立刻拒绝并给稳定 code", busyError?.code === "TURN_OUTLINE_BUSY", String(busyError?.code));
      check("有界队列：并发恒为 1（第二个未抢占执行槽）", order.join(",") === "first-start", order.join(","));
      releaseFirst();
      const settled = await Promise.all([first, second, third]);
      check(
        "有界队列：串行完成且顺序正确",
        settled[0] === "a" && settled[1] === "b" && settled[2] === undefined && order.join(",") === "first-start,first-end,second",
        order.join(","),
      );

      const queue2 = mod.createTurnOutlineQueue({ maxQueue: 2 });
      let release2;
      const gate2 = new Promise((resolve) => { release2 = resolve; });
      const controller = new AbortController();
      let queuedRan = false;
      const running = queue2.run(async () => { await gate2; });
      const queued = queue2.run(async () => { queuedRan = true; }, { signal: controller.signal });
      controller.abort(Object.assign(new Error("deadline passed while queued"), { name: "TimeoutError" }));
      release2();
      await running;
      let queuedError;
      await queued.catch((error) => { queuedError = error; });
      check(
        "有界队列：排队期间已超时的任务出队即拒、不执行",
        queuedRan === false && queuedError?.name === "TimeoutError",
        `ran=${queuedRan} name=${queuedError?.name}`,
      );

      // 截止时间到达时**立刻**拒绝排队中的任务，而不是等执行槽空出
      // （否则 App 已超时放弃、服务端还在替它排队）。
      const queue3 = mod.createTurnOutlineQueue({ maxQueue: 2 });
      let release3;
      const gate3 = new Promise((resolve) => { release3 = resolve; });
      const controller3 = new AbortController();
      let queuedRan3 = false;
      const running3 = queue3.run(async () => { await gate3; });
      const queued3 = queue3
        .run(async () => { queuedRan3 = true; }, { signal: controller3.signal })
        .catch((error) => { queuedError = error; });
      controller3.abort(Object.assign(new Error("deadline"), { name: "TimeoutError" }));
      await new Promise((resolve) => setTimeout(resolve, 0));
      check(
        "有界队列：排队中的任务在截止时间到达时立即被拒（不等执行槽）",
        queuedError?.name === "TimeoutError" && queuedRan3 === false && queue3.pending === 0,
        `ran=${queuedRan3} pending=${queue3.pending}`,
      );
      release3();
      await running3;
      await queued3;

      // 预取消 signal：在容量判断**之前**就拒，不白占队列条目（第二轮评审 P3）。
      const queue4 = mod.createTurnOutlineQueue({ maxQueue: 1 });
      let release4;
      const gate4 = new Promise((resolve) => { release4 = resolve; });
      const running4 = queue4.run(async () => { await gate4; });
      const pre = new AbortController();
      pre.abort(Object.assign(new Error("already aborted"), { name: "AbortError" }));
      let preError;
      let preRan = false;
      await queue4
        .run(async () => { preRan = true; }, { signal: pre.signal })
        .catch((error) => { preError = error; });
      let liveAccepted = true;
      const live = queue4.run(async () => "live").catch(() => { liveAccepted = false; });
      await new Promise((resolve) => setTimeout(resolve, 0));
      check(
        "有界队列：预取消 signal 立即被拒且不占容量（后续有效任务不被挤成 busy）",
        preError?.name === "AbortError" && preRan === false && queue4.pending === 1 && liveAccepted === true,
        `pre=${preError?.name} ran=${preRan} pending=${queue4.pending}`,
      );
      release4();
      await running4;
      await live;

      // 有界等待：响应与工作分离（第二轮评审 P1）。
      if (typeof mod.raceWithDeadline === "function") {
        let resolveWork;
        const work = new Promise((resolve) => { resolveWork = resolve; });
        const settledFirst = await mod.raceWithDeadline(
          Promise.resolve("done"),
          { deadlineMs: 200 },
        );
        check(
          "raceWithDeadline：工作先完成 → settled",
          settledFirst.status === "settled" && settledFirst.value === "done",
          JSON.stringify(settledFirst),
        );
        const lateValues = [];
        const timedOut = await mod.raceWithDeadline(work, { deadlineMs: 30, onLate: (value) => lateValues.push(value) });
        check("raceWithDeadline：到截止时间 → timedOut（不回写成功）", timedOut.status === "timedOut", JSON.stringify(timedOut));
        check("raceWithDeadline：截止时迟到的结果尚未处理（工作仍在进行）", lateValues.length === 0, JSON.stringify(lateValues));
        resolveWork("late-lease");
        await new Promise((resolve) => setTimeout(resolve, 10));
        check(
          "raceWithDeadline：底层完成后把迟到结果交给 onLate（用于 dispose 迟到 lease）",
          lateValues.length === 1 && lateValues[0] === "late-lease",
          JSON.stringify(lateValues),
        );
        const preAborted = new AbortController();
        preAborted.abort();
        const timedOutBySignal = await mod.raceWithDeadline(new Promise(() => {}), {
          deadlineMs: 5000,
          signal: preAborted.signal,
        });
        check("raceWithDeadline：已取消的 signal → 立即 timedOut", timedOutBySignal.status === "timedOut", JSON.stringify(timedOutBySignal));

        // 第三轮评审 P3：work 先完成时也要清掉定时器/监听器，不留无用资源。
        let listenerAdded = 0;
        let listenerRemoved = 0;
        const fakeSignal = {
          aborted: false,
          addEventListener() { listenerAdded += 1; },
          removeEventListener() { listenerRemoved += 1; },
        };
        const startedAt = Date.now();
        const quick = await mod.raceWithDeadline(Promise.resolve("ok"), { deadlineMs: 60_000, signal: fakeSignal });
        check(
          "raceWithDeadline：work 先完成 → 立即 settled（不等 60s 截止）",
          quick.status === "settled" && quick.value === "ok" && Date.now() - startedAt < 1000,
          `${JSON.stringify(quick)} took=${Date.now() - startedAt}ms`,
        );
        check(
          "raceWithDeadline：竞速结束后移除 abort listener（不留无用监听）",
          listenerAdded === 1 && listenerRemoved === 1,
          `added=${listenerAdded} removed=${listenerRemoved}`,
        );
      } else {
        check("导出 raceWithDeadline", false, "missing export");
      }
    } else {
      check("导出 createTurnOutlineQueue", false, "missing export");
    }
    // 能力探测：三种情形（只有服务 / 只有单元 / 单元+观察接口），与端点判据同源。
    check(
      "turnOutlineCapabilityOf：服务存在≠支持，单元+观察接口才算支持",
      typeof mod.turnOutlineCapabilityOf === "function"
        && mod.turnOutlineCapabilityOf({ get: (name) => (name === "sessionProjections" ? {} : undefined) }).supported === false
        && mod.turnOutlineCapabilityOf({ get: (name) => (name === "sessionProjections" ? { registrations: new Map([["turnOutline", {}]]) } : undefined) }).supported === false
        && mod.turnOutlineCapabilityOf({
          get: (name) => (name === "sessionProjections"
            ? { registrations: new Map([["turnOutline", {}]]) }
            : name === "sessionQuery"
              ? { observeSession() {} }
              : undefined),
        }).supported === true,
      "capability probe mismatch",
    );

    // ── 端点级定时/取消测试（第二轮评审 P1/P2）──
    // 两个**独立实例**（各自一个执行槽，互不排队干扰）；截止时间压到 60ms 以便门禁里做定时断言。
    const { EventEmitter } = await import("node:events");
    const buildTimedInstance = () => {
      const observed = [];
      const disposed = [];
      let release;
      const hangGate = new Promise((resolve) => { release = resolve; });
      const servicesT = {
        sessions: { get: () => undefined, list: () => [] },
        agents: { get: () => undefined, list: () => [] },
        sessionProjections: { registrations: new Map([["turnOutline", {}]]) },
        sessionQuery: {
          async observeSession(id, options) {
            observed.push({ id, signal: options?.signal });
            // 不合作观察：完全不看 signal，只有测试放行才结束。
            if (id.startsWith("hang")) await hangGate;
            return {
              projections: { asOfSeq: 1, values: { turnOutline: [] } },
              [Symbol.dispose]() { disposed.push(id); },
            };
          },
        },
      };
      const routesT = [];
      const ctxT = {
        logger: { info() {}, warn() {}, error() {}, debug() {} },
        get: (name) => servicesT[name],
        on: () => () => {},
        inject() {},
        provide() {},
        effect(fn) { const dispose = fn(); return typeof dispose === "function" ? dispose : () => {}; },
        waterfall: async (_name, _args, next) => next(),
        webServer: { host: "127.0.0.1", port: 3080, register(route) { routesT.push(route); return () => {}; } },
      };
      mod.apply(ctxT, mod.Config({
        path: "/m",
        authToken: "secret-secret-secret-1234",
        pushUrls: [],
        lanBridge: { enabled: false },
        turnOutlineTimeoutMs: 60,
      }));
      return { route: routesT.find((r) => r.path === "/m/api"), observed, disposed, release: () => release() };
    };
    const timedCall = async (route, url, attempts = 200) => {
      const res = response();
      route?.handler(request(url), res);
      for (let i = 0; i < attempts && !res.ended; i++) await new Promise((resolve) => setTimeout(resolve, 5));
      return res;
    };

    const timedA = buildTimedInstance();
    const slowRes = await timedCall(timedA.route, "/m/api/turn-outline?sessionId=hang-slow");
    check(
      "端点级：执行中的不合作观察也在截止时间回 turn-outline-timeout（不无限等待）",
      slowRes.ended && slowRes.json?.code === "turn-outline-timeout" && slowRes.json?.state === "read-failed",
      JSON.stringify(slowRes.json),
    );
    check("端点级：响应已结束但观察仍未结束（迟到 lease 尚未释放）", timedA.disposed.length === 0, JSON.stringify(timedA.disposed));
    timedA.release();
    await new Promise((resolve) => setTimeout(resolve, 30));
    check("端点级：迟到 lease 在底层完成后被释放（不泄漏 pin、不回写成功）", timedA.disposed.length === 1, JSON.stringify(timedA.disposed));
    const afterLate = await timedCall(timedA.route, "/m/api/turn-outline?sessionId=ok-after");
    check(
      "端点级：迟到观察结束后执行槽释放，后续请求正常成功",
      afterLate.json?.state === "empty",
      JSON.stringify(afterLate.json),
    );

    const timedB = buildTimedInstance();
    const reqB = Object.assign(new EventEmitter(), {
      url: "/m/api/turn-outline?sessionId=hang-disconnect",
      method: "GET",
      headers: { host: "127.0.0.1:3080", "x-mobile-token": "secret-secret-secret-1234" },
      socket: { remoteAddress: "127.0.0.1" },
      pause() {},
      resume() {},
    });
    let bWriteHead = 0;
    let bEnd = 0;
    const resB = Object.assign(new EventEmitter(), {
      statusCode: 0,
      headersSent: false,
      writableEnded: false,
      ended: false,
      writeHead(status) { bWriteHead += 1; this.statusCode = status; this.headersSent = true; },
      setHeader() {},
      write() { return true; },
      end() { bEnd += 1; this.writableEnded = true; this.ended = true; },
      destroy() { this.ended = true; },
    });
    timedB.route.handler(reqB, resB);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const signalBefore = timedB.observed.at(-1)?.signal;
    check(
      "端点级：断开前观察拿到的 signal 未 aborted（正常请求不误判为断开）",
      signalBefore !== undefined && signalBefore.aborted === false,
      `signal=${signalBefore === undefined ? "missing" : signalBefore.aborted}`,
    );
    reqB.emit("aborted");
    await new Promise((resolve) => setTimeout(resolve, 40));
    check(
      "端点级：客户端断开 → 观察的 signal 被 abort（不再白占唯一执行槽）",
      timedB.observed.at(-1)?.signal?.aborted === true,
      `aborted=${timedB.observed.at(-1)?.signal?.aborted}`,
    );
    check(
      "端点级：断开后不再向已断开的响应写入（writeHead/end 均为 0）",
      bWriteHead === 0 && bEnd === 0,
      `writeHead=${bWriteHead} end=${bEnd}`,
    );
    timedB.release();
    await new Promise((resolve) => setTimeout(resolve, 30));
    check("端点级：断开后迟到 lease 仍被释放", timedB.disposed.length === 1, JSON.stringify(timedB.disposed));

    // 仅 res 'close'（未 end、未 aborted）：同样取消且不写响应。
    const timedC = buildTimedInstance();
    const reqC = Object.assign(new EventEmitter(), {
      url: "/m/api/turn-outline?sessionId=hang-close",
      method: "GET",
      headers: { host: "127.0.0.1:3080", "x-mobile-token": "secret-secret-secret-1234" },
      socket: { remoteAddress: "127.0.0.1" },
      pause() {},
      resume() {},
    });
    let cWrites = 0;
    const resC = Object.assign(new EventEmitter(), {
      statusCode: 0,
      headersSent: false,
      writableEnded: false,
      destroyed: true,
      ended: false,
      writeHead() { cWrites += 1; },
      setHeader() {},
      write() { return true; },
      end() { cWrites += 1; this.writableEnded = true; },
    });
    timedC.route.handler(reqC, resC);
    await new Promise((resolve) => setTimeout(resolve, 20));
    resC.emit("close");
    await new Promise((resolve) => setTimeout(resolve, 40));
    check(
      "端点级：仅 res.close（未 end）也取消，且不写入已断开的响应",
      timedC.observed.at(-1)?.signal?.aborted === true && cWrites === 0,
      `aborted=${timedC.observed.at(-1)?.signal?.aborted} writes=${cWrites}`,
    );
    timedC.release();
    await new Promise((resolve) => setTimeout(resolve, 30));
    check("端点级：仅 close 场景的迟到 lease 仍被释放", timedC.disposed.length === 1, JSON.stringify(timedC.disposed));
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
