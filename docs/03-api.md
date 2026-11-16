# 03 API 接口设计文档 — dsh-mobile-remote

> 版本：v3.2.0 · 状态：已实现 · 配套：00-开发总纲.md、02-architecture.md、04-security.md、09-compatibility.md
> 前缀：`/m`（可配置项 `path`，默认 `/m`）。以下所有路径均以前缀开头。
> 服务端 API 同时服务 Flutter App（dsh-mobile-app）与桌面设置页客户端模块；不含网页版页面（v2.1 起移除）。
## 1. 通用约定

- **内容类型**：JSON API 一律 `application/json; charset=utf-8`；错误统一 `{ "error": string, "detail"?: string }`。
- **鉴权**：`authToken` 配置为空 → 无鉴权；非空 → 除 `GET /m/api/qr-config`（仅 loopback）外，所有端点要求凭证。
- **凭证形式**（二选一，任一通过即可）：
  - 请求头：`X-Mobile-Token: <token>`（App 使用）
  - Cookie：`dsh_mobile_token=<token>`（兼容保留，无登录入口）
- **未认证响应**：`401 { "error": "auth-required", "detail": "访问口令未通过验证" }`。
- **路由匹配**：`/m/api/*` 按前缀注册；未知子路径 → `404 { "error": "not-found" }`；`/m` 之外的裸路径不拦截（fallback 仍归桌面 SPA）。
## 2. 端点总表

| 方法 | 路径 | 用途 | 鉴权 |
|---|---|---|---|
| GET | `/m/api/bootstrap` | 初始状态：地址、认证要求、agent 摘要、会话列表 | 是 |
| POST | `/m/api/send` | 向指定/默认 agent 注入消息（v2.7.2 支持 `mode: "steer"` 插队） | 是 |
| GET | `/m/api/queue` | 排队消息列表（对齐 PC 端 Queue Dock；`placement: "queued"` 可插话、`"steering"` 不可，v2.7.2） | 是 |
| POST | `/m/api/messages` | 排队消息操作：`{ sessionId, itemId, action: { kind: "edit"|"remove"|"steer", content? } }`（转发内核 `session.updateQueue`；错误码如 `queue-item-not-found`/`steer-unavailable` 透传，v2.7.2） | 是 |
| GET | `/m/api/sessions` | 会话列表 | 是 |
| GET | `/m/api/history` | 指定会话的 Conversation timeline 历史（按 seq 分页） | 是 |
| GET | `/m/api/event-detail` | 单个 Visible event 无损详情（按 seq） | 是 |
| GET | `/m/api/turn-outline` | 会话轮次大纲（只读投影；轮次号 / 起始序号 / 提示词与回复预览，轮次导航） | 是 |
| GET | `/m/api/events` | SSE 事件流（session/event 摘要） | 是 |
| GET | `/m/api/catalog` | 模型/推理/权限/预设目录 | 是 |
| GET/POST | `/m/api/session-config` | 会话配置（读写） | 是 |
| POST | `/m/api/sessions` | 新建会话 | 是 |
| POST | `/m/api/sessions/touch` | 标记会话被打开（最近活跃排序） | 是 |
| POST | `/m/api/sessions/archive` | 归档会话 | 是 |
| POST | `/m/api/sessions/unarchive` | 恢复（取消归档） | 是 |
| POST | `/m/api/sessions/stop` | 停止（取消）会话当前运行 | 是 |
| POST | `/m/api/sessions/fork` | 在新对话中分支（映射内核 `session.fork`） | 是 |
| GET/POST | `/m/api/feedback` | 消息反馈 👍/👎（内核 `messageFeedback` 服务，与 PC 端同一份） | 是 |
| GET | `/m/api/notifications` | 通知列表 | 是 |
| POST | `/m/api/notifications/read` | 标记已读 | 是 |
| POST | `/m/api/notifications/delete` | 删除通知记录（单条/批量/全部） | 是 |
| POST | `/m/api/respond` | 回答内核问询/审批（与 PC 端 GUI 同一 respond 通道） | 是 |
| GET | `/m/api/actions` | 插件动作清单 | 是 |
| POST | `/m/api/actions/:id/invoke` | 执行插件动作 | 是 |
| GET | `/m/api/usage` | 会话 token 用量 | 是 |
| GET | `/m/api/workspaces` | 已注册工作区 | 是 |
| GET/POST | `/m/api/directories` | 目录浏览/新建文件夹 | 是 |
| GET | `/m/api/diagnostics` | 环境诊断 | 是 |
| GET | `/m/api/balance` | DeepSeek 官方余额 | 是 |
| GET | `/m/api/account-usage` | 用量与额度（DeepSeek / Codex / OpenCode Go） | 是 |
| GET | `/m/api/qr-config` | 桌面二维码数据（loopback only） | 否（loopback） |
| POST | `/m/api/defaults` | 修改默认 Agent/权限预设 | 是 |
| GET/POST | `/m/api/llm-providers` | 模型提供商列表 / 保存配置（v2.6） | 是 |
| POST | `/m/api/llm-providers/probe` | 探测端点模型列表（v2.6） | 是 |
| GET | `/m/qr.png` | 二维码 PNG | 否 |
| GET | `/m/api/jobs` | 会话后台任务列表（v2.7，内核 jobs 同源） | 是 |
| POST | `/m/api/jobs/kill` | 取消任务（v2.7，映射 `jobs.kill`） | 是 |
| GET | `/m/api/subagents` | 子代理列表（v2.7，按父会话 `subagent.list`） | 是 |
| POST | `/m/api/subagents/interrupt` | 中断子代理（v2.7，`subagent.interrupt`） | 是 |
| GET/POST | `/m/api/goal` | 当前目标 / 创建·暂停·继续·完成（v2.7，goal RPC 同源） | 是 |
| GET/POST | `/m/api/commands` | 斜杠命令目录/执行（v2.8.0；v2.8.2 适配内核 0.1.1-rc.2 四参签名，服务缺失优雅降级） | 是 |

## 3. 端点详述（v1 既有端点）
### 3.1 GET /m/api/bootstrap

**响应 200**

```json
{
  "ok": true,
  "auth": { "enabled": false },
  "server": {
    "port": 3080,
    "urls": ["http://192.168.1.5:3080", "http://100.101.102.103:3080", "http://127.0.0.1:3080"]
  },
  "capabilities": {
    "eventTimeline": {
      "version": 1,
      "live": true,
      "history": true,
      "detail": true,
      "unknownEvents": true,
      "callCorrelation": true
    },
    "turnOutline": { "version": 1, "supported": true, "unloaded": true, "truncated": true }
  },
  "agents": [
    { "id": "session-abc", "status": "running", "hasPending": false }
  ],
  "sessions": [
    { "id": "session-abc", "createdAt": 1750000000000, "cwd": "F:\\DSH-Outpost" }
  ]
}
```

- `urls`：按优先级排列——默认「局域网私有地址优先」（`10./192.168.x` → `172.16-31` → Tailscale CGNAT `100.64/10` → 其他），首个非 internal IPv4 在前，loopback 最后；**仅当机器上没有任何局域网私有地址时**，才把 Tailscale CGNAT 提到最前（issue #49，避免校园网/热点等场景选出不可达地址）；`port` 来自 `ctx.webServer.port`。v3.0.0：`lanBridge` 监听成功时首选地址为桥地址（`http://<IP>:<lanBridge.port>`，端口默认 3080），回环 webserver 地址仅作本机自连兜底。
- `agents[].status`：`"running" | "idle"`（映射自 agent 状态与最近事件推断）。
- `capabilities.turnOutline`：轮次大纲能力位（轮次导航）。宿主**真的注册了** `turnOutline` 投影单元、且投影感知观察面（`sessionQuery.observeSession`）可用时，返回 `{ "version": 1, "supported": true, "unloaded": true, "truncated": true }`——`unloaded` 表示未加载轮次也可跳转、`truncated` 表示超过体积上限会显式截断；否则返回 `{ "version": 1, "supported": false }`。**不按宿主版本号推断**：旧宿主/裁剪宿主显式声明不支持，App 据此退回「只用已加载轮次」的降级行为。SSE hello 的同名字段与该处**同判据、同形状**（见 §3.6 与 §6.18）。
- 未认证：`401`（见通用约定）。
### 3.2 POST /m/api/send
**请求**

```json
{ "sessionId": "session-abc", "text": "帮我跑一下测试", "mode": "steer" }
```

- `requestId` 可选（**v3.0.0 热修 05**）：客户端生成的 UUID（`^[A-Za-z0-9-]{8,64}$`，非法 → `400 invalid requestId`）。携带时服务端启用**幂等回执**：投递之前占位 in-progress，处理完成后记录结果快照；同一 `sessionId+requestId` 的重复请求**直接返回第一次结果、不再二次投递**（`Connection reset by peer` 后重试不会产生重复消息）。回执经 `GET /m/api/send-receipt` 查询；单进程内 + TTL 15 分钟幂等，持久化于 `~/.dsh/mobile-remote/send-receipts.json`（重启恢复；处理中状态不跨重启保留）。

图片发送（v3.0.0 图像链路，与 PC 端 wire 同形，原始字节不压缩）：

```json
{ "sessionId": "session-abc", "text": "这是什么", "images": [{ "mediaType": "image/png", "data": "<base64>", "name": "photo.png" }] }
```

- `sessionId` 可选：指定会话（必须存在且其 agent 存活）；缺省 → 第一个 root agent。
- `mode` 可选（v2.7.2）：`"followup"`（默认，排队到下一轮）| `"steer"`（插队：消息插到 agent 下一步执行，适合 team 插件子会话向主会话插队）。agent 空闲时 `steer` 自动降级为 `followup`，响应 `note: "agent-idle-followup"`。
- `images` 可选（v3.0.0）：`[{ mediaType(仅 png/jpeg/webp/gif), data(canonical base64 原始字节), name? }]`——经内核 `session.prompt` 图片通道（内核限额/降采样/附件落盘，与 PC 端完全同一通路；纯文本仍走 followup）。超限/非规范 → `attachment-error`（`IMAGE_TOO_LARGE`/`INVALID_IMAGE_BASE64` 等）。请求体上限 64MB；**移动端客户端总量上限 40MB（热修 05）**——64MB body 扣掉 base64 膨胀（×4/3）与 JSON 开销后的安全值，超限在客户端明确提示、不落到服务端 413；内核侧 200MB 能力不受影响（PC 端同源）。**mediaType 纠正（v3.0.0 热修 02）**：服务端按字节魔数（PNG/JPEG/GIF/WebP/HEIC）嗅探真实类型，声明与字节不符自动纠正（warn 记录）；未识别类型原样交内核裁决。图片路径 200 响应带 `accepted: true`（与文本路径语义一致）。
- **v3.0.0（方案 A）**：`followup` 且 agent **运行中**时，消息**不进内核 next-turn**（内核会在当前轮结束瞬间自动认领执行，PC 端同款语义），而是**插件侧持存**——只出现在 Queue Dock/移动端 dock，**不渲染进对话窗口**（与 PC 端一致）；agent 真正空闲（整个任务/目标结束）后按序自动释放为 `followup`。持存期间消息可经 `/messages` 删除/编辑/插队（全部插件侧执行，无认领竞态）。响应 `mode: "queued", note: "held-until-idle"`。持存文件 `~/.dsh/mobile-remote/held-queue.json`，插件重启不丢。图片持存同样支持（base64 随持存落盘，重启恢复；插队=立即 prompt steer）。
**响应**

- `200 { "ok": true, "agentId": "session-abc", "messageId": "m_<uuid>", "mode": "followup" | "steer" | "queued" }`（`mode: "queued"` 时附 `note`；图片路径 `note: "image-prompt"`）
- `400 { "error": "empty-text" }`：text 为空或非字符串
- `404 { "error": "session-not-found" }`：指定会话不存在
- `503 { "error": "no-live-agent" }`：无匹配的运行中 agent
- `503 { "error": "agents-unavailable" }`：agents 服务不可用（非 web 组合或启动中）
**语义**：服务端构造 `createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })` 后调用 `agent.followup(message)`（排队/空闲释放）或 `agent.steer(message)`（插队）；运行中 `followup` 走持存（见上）；含 `images` 时经内核 `session.prompt` 图片通道。`followup` 会持久化消息并唤醒空闲驱动器；不等待执行结果（结果经 SSE 回流）。

### 3.2c GET /m/api/send-receipt（v3.0.0 热修 05，发送回执查询）

**查询参数**：`sessionId`（与发送时一致；缺省按 root agent 解析）、`requestId`（必填，非法 → `400 invalid requestId`）。
**响应**：`200 { "ok": true, "receipt": { "status": "done" | "error" | "in-progress", "result": {...} } }`（`result` 为发送响应快照，含 messageId/accepted/note/mode）；未命中 → `404 receipt-not-found`。
**语义**：客户端在传输层错误（reset/超时）后用**同一个 requestId** 查询——`done` 即确认已送达（请勿重发）；`in-progress` 稍后轮询；`404` 表示第一次请求未到达服务端（可重试，同 id 幂等）。此端点**不投递任何消息**。

### 3.2b GET /m/api/attachment（v3.0.0 图像链路，渲染取图）

**查询参数**：`sessionId`、`attachmentId`（均必填，来自 SSE/history 摘要的 `images[].attachmentId`）。
**响应**：`200` 原始字节（`Content-Type` 按 `mediaType`，`Cache-Control: private, max-age=3600`，`x-attachment-meta` 带 width/height/bytes/name）；`400` 缺参；`404 attachment-not-found`；其他错误透传。鉴权与其他端点一致（`x-mobile-token`/cookie）。
### 3.3 GET /m/api/sessions

**响应 200**

```json
{
  "ok": true,
  "sessions": [
    {
      "id": "session-abc",
      "createdAt": 1750000000000,
      "cwd": "F:\\DSH-Outpost",
      "live": true,
      "title": "会话标题（活动会话）",
      "archived": false,
      "lastActivity": 1750000123456
    }
  ]
}
```

- **默认排除零可见消息的空会话**（issue #109）：没有 `user/message`（真人发言）或非空 `assistant/message` 的会话不返回，避免“创建过但从未对话”的空会话出现在列表。`?includeEmpty=1` 返回全部（排查/清理用）；其他值（含缺失、`0`、`true`、非法串）按 false 处理。
- “可见消息”与 `lastMessageAt` 同口径：仅 `user/message`（`source.kind` 为 `user`/旧内核无 source）和正文非空的 `assistant/message`；`tool/call`、`tool/result`、权限/sandbox/approval/model selection、`session/end-seed`、系统注入等都不计入。空会话仍可通过 includeEmpty 或深链访问。
- 过滤在标题折叠与消息时间回填之后执行；休眠/归档空会话同样默认隐藏。空会话 = **零可见对话消息且无 `tool/call`/`tool/result`**（工具活动是有价值内容，不能当空会话删除）；纯配置/生命周期/空 assistant/系统注入不算对话。判空**不看 `time`**：可见消息没有时间戳时仍保留（仅排序回退 `lastActivity`/`createdAt`）。
- 优先用 `ctx.sessionPersistence.list()` 的廉价 metadata 判空：实测空会话 4–7 个事件、压缩后 329–704B；正常对话实测最小 22 事件/40KB。实现阈值：`eventCount ≤ 8` 且 `sizeBytes ≤ 2048`（eventCount 缺失时仅看 sizeBytes ≤2048）；eventCount 小但文件大（可能含工具调用/长参数）保留。
- metadata 不足（服务缺失/条目缺失）才退回有界 `readSession`；只删**本次请求成功读到且确认空**的会话；读取失败、超出预算、仍在途、旧回填缓存一律保留可见，宁可多显示也不误删。兜底读取受单次 deadline + 总 2.5s 硬上限约束，并发 ≤4。
- 排序（规划中）：优先按 `lastMessageAt` 倒序，缺失时回退 `lastActivity`，再回退 `createdAt`；等值时以 `id` 为次级键保证顺序稳定。数据源：优先 `sessionQuery.listSessions()`（含休眠会话），回退 `ctx.sessions.list()`（仅活动会话）。
- `archived`：是否已归档（见 3.4 归档接口）。
- `lastActivity`：最近活跃时间（ms）。任意会话事件（SSE）与移动端"打开会话"（3.4 touch）都会更新，持久化于 `~/.dsh/mobile-remote/session-activity.json`。

### 3.4 归档 / 活跃时间接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/m/api/sessions/touch` | 标记会话被打开（更新 lastActivity） |
| POST | `/m/api/sessions/archive` | 归档会话（映射内核 `workspace.archiveSession`，与 PC 端同一份状态） |
| POST | `/m/api/sessions/unarchive` | 恢复（取消归档） |
| POST | `/m/api/sessions/stop` | 停止（取消）会话当前运行（映射核心 RPC `session.cancel`） |

请求体统一为 `{ "sessionId": "session-abc" }`。

- `touch` 响应：`200 { "ok": true, "lastActivity": 1750000123456 }`
- `archive` / `unarchive` 响应：`200 { "ok": true, "archived": true|false }`
- `stop` 响应：`200 { "ok": true, "accepted": true }`；失败时 `400 { "error": "cancel-failed" }`（v2.8.0 起统一 rpcError 映射：内核错误透传 status+code、传输层 502、超时 504；旧版固定 500）
- 归档状态即内核 `workspaceRegistry.archivedSessionIds`（与 PC 端同一份）：PC 端归档的会话在移动端同样显示为已归档，反之亦然。归档会话仍出现在 3.3 列表中（`archived: true`），由客户端分栏展示。

### 3.5 GET /m/api/history

**查询参数**

- `sessionId`（必填）：目标会话
- `after`（可选）：**增量模式**——只返回 `seq > after` 的事件（SSE 重连补漏用）。
- `before`（可选）：**上翻分页**——只返回 `seq < before` 的最近 `limit` 条事件（对话内滚动到顶部加载更早）。
- 三种模式优先级：`after` > `before` > 初始加载（缺省时返回最近 `limit` 条，即尾部）。
- `limit`（可选，默认 500，上限 1000）：最多返回条数
**过滤规则**：返回可进入 Conversation timeline 的事件；`assistant/chunk` / `assistant/live-chunk` 只用于实时草稿，`agent/inbox/spliced` 由队列投影承载，`request/header`（含 system prompt/tool schema）、`request/context`、`session/title-llm-request` / `web/deepseek-search-llm-request`（LLM 请求快照：data 含 `system` 系统提示词与 `messages` 对话正文）、`session/end-seed`、`step/start`、`step/end`、`system/message`、`assistant/attempt`（重试/中断的原始 stream 记录）与 `compaction/start` / `compaction/summary` / `compaction/prune` / `compaction/end`（压缩生命周期；summary 正文即替换 shadowed 区间后的上下文快照）属于内部/重建/快照元数据，历史、实时与 3.5b 详情三处都不返回。`compaction/end` 作为不落卡片的实时控制帧通知 App 重新加载 durable snapshot。

未知 type（即使带 `ignorable: true`）**保留 `seq`/`type` 进入时间线**（事件保真：不能因客户端尚未认识类型而静默丢弃），但**不下发详情指针**——`detail.available` 只对下方 allow-list 内的可见类型为真，其余类型调 3.5b 返回 `404 event-not-found`。这保证「新类型照常可见」与「未命名记录的原始载荷不外泄」同时成立（fail-closed）。

**详情可见类型（allow-list）**：`user/message`、`assistant/message`、`tool/call`、`tool/result`、`todo/write`、`turn/start`、`turn/end`。

判定依据：这几类正是 `summarizeEventCore` **逐个类型显式审过载荷**并下发给 App 的类型；其余类型走 default 分支只给 `{seq, type}`，App 从不消费其 data。`assistant/chunk` / `assistant/live-chunk` 虽被 App 消费，但属于实时草稿（不落 durable 历史），故不在名单内。

**有意的 fail-closed 取舍**：`approval/*`、`question/*`、`session/jobs`、`session/title`、`subagent/*`、`command/*`、`tool/ptc-dispatch*` 这些 App 会渲染卡片、但插件**尚未审过载荷**的类型当前**不在** allow-list —— 调试模式下展开这类卡片会显示「详情不可用」。原因是它们可能携带 prompt / 命令正文（如 `subagent/descriptor`、`command/run`）。要放行某个类型，需先逐类型审计载荷，然后**同时**改服务端 `DETAIL_VISIBLE_TYPES` 与 App 侧详情入口白名单。

> 客户端呈现约定：`session/title`、`model/selection`、`sandbox/mode`、`agent-preset/selected`、`subagent/*`、`team/*`、`feedback/*`、`command/*`、`approval/policy`、`tool/ptc-dispatch*`、`goal/change`、`plan/mode`、`permission/preset`、`schedule/change`、`hook/*`、`llm/retry*`、`deliverables/presented`、`tool-workflow/*`、`session-log-deepseek/delivery-accepted`、`subagent/model-selection-policy` 属协议/运行时元数据——仍下发并保留 `seq`，但普通模式不渲染，调试模式可展开审阅（见 05-test-cases F-34）。`approval/asked` / `approval/decided` 是 durable 审批记录，普通模式以可读标题呈现（历史回放的权威源；问询只有瞬态帧，不保证回放）。
**响应 200**

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "after": 42,
  "hasMore": false,
  "events": [
    { "seq": 43, "type": "user/message", "detail": { "available": true, "seq": 43 }, "data": { "text": "帮我跑一下测试" } }
  ]
}
```

`events[]` 使用与 SSE 帧相同的摘要格式（见 3.6），保证客户端去重逻辑单一。数据源：`ctx.sessions.get(id).events`（追加式冻结快照，天然按 seq 有序）。
- `404 { "error": "session-not-found" }`

### 3.5b GET /m/api/event-detail

按会话和 durable `seq` 读取单个 Visible event 的无损详情。该端点需要认证；服务端优先使用 `sessionQuery.readEvent`，旧内核回退到活动会话快照或休眠会话读取。

查询参数：`sessionId`、`seq`。

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "event": {
    "seq": 43,
    "type": "tool/result",
    "time": 1750000000000,
    "surfaceOp": "append",
    "sourceEventSeqs": [42],
    "data": { "callId": "call-1", "isError": false, "text": "完整结果" }
  }
}
```

当服务端只能从 seeded session 的当前 surface 读取时，成功响应额外包含 `"degraded": true, "detailMode": "current-surface"`；客户端必须保留该元数据并提示详情可能不完整。详情不存在或属于内部/敏感类型返回 `404 event-not-found`；单事件详情超过 8 MiB 返回 `413 event-detail-too-large`。

稳定错误矩阵：`session-not-found`（会话不存在）、`event-not-found`（seq 不存在/不可见/无详情权限）、`session-corrupt`（会话数据损坏）、`event-read-failed`（读取失败）和 `event-detail-too-large`（超过 8 MiB）。错误响应不得泄露主机路径或原始异常；旧服务端未保存详情时客户端显示安全错误并提供重试，不猜测重建。

> 命名说明：本端点的读取失败码是 **`event-read-failed`**（单事件级），与 `/m/api/history` 的 **`session-read-failed`**（整会话回放失败）语义不同，**不要**为"统一"而合并——App 侧对两者有各自的文案与重试路径。

**规范化正文（`text`）**：`assistant/message` 的详情响应额外附 `data.text`，由服务端用**与事件摘要同一个 `blocksToText`** 提取（只拼 `type == "text"` 的块，跳过 `reasoning` 与内部块），因此与摘要下发的 `text` 同源同规则。客户端必须直接采用该字段作为正文，**不得自行递归拼接 `message.content`**——那会把 `reasoning` 块并进正文，使思维链在折叠块之外重复出现（issue #1 需求变更记录）。`tool/result` 等其它类型的详情仍以原始事件载荷为准；原始 `message` 块原样保留。

### 3.6 GET /m/api/events（SSE）
`Content-Type: text/event-stream`。帧格式（`data:` 单行 JSON）：

```json
{ "type": "session/event", "sessionId": "session-abc", "event": { "seq": 44, "type": "turn/end", "data": { "reason": { "kind": "complete" } }, "detail": { "available": true, "seq": 44 } } }
```

**事件摘要 `event` 字段**：实时和历史使用同一摘要 envelope；摘要可包含 `detail: { available: true, seq }`，长参数/结果通过 3.5b 按需读取，不在列表中静默截断。只有 `/event-detail` 真能取回的事件才带该指针（token delta 与内部/快照记录不带，避免客户端显示必然 404 的详情按钮）。

`assistant/message` 的指针额外带 **`textChars`**：与摘要同 `blocksToText` 口径的**未截断**正文长度。客户端据此**在加载前**判断「详情是否真有正文增量」（`textChars > 当前可见正文长度`），从而普通模式只在确有增量时显示加载入口；调试模式不受此限，始终提供「查看原始事件」。该字段为纯增量，旧客户端忽略即可。

| event.type | event.data 内容 |
|---|---|
| `user/message` | `{ text: string }`（text blocks 拼接，≤2000 字符）；v3.0.0 起附图 `images: [{ attachmentId, mediaType, width?, height?, name? }]`；文件块可带 `files: [{ attachmentId?, path?, name?, mediaType?, size? }]`（**用户自己的附件，保留**；App 只显示文件名/类型/大小，不提供下载——issue #1 需求变更） |
| `assistant/message` | `{ text: string, reasoningChars: number, reasoning?: string }`（`reasoning` 为思维链正文，仅当非空时下发，供移动端折叠块；≤20000 字符）；v3.0.0 起附图 `images: [...]`（同上）；**v3.0.0 版本二**：`images` 含嵌套收集——`tool-result.content` 内的图片块（read_image 等工具结果）与顶层图一并带出（对齐 PC 端 contentParts 语义）；**文件块不再下发 `files`**（issue #1 需求变更：时间线不提供产出文件的下载入口） |
| `assistant/chunk` / `assistant/live-chunk` | `{ text: string }` 文本/reasoning delta；工具参数 delta 的 canonical `chunk.id` 归一为摘要 `callId`（仅实时过程，历史过滤） |
| `tool/call` | `{ turn, step, callId, name, arguments }`；长参数可通过详情端点获取 |
| `tool/result` | `{ callId, name, isError, text, images? }`；长结果可通过详情端点获取；**不再下发 `files`**（issue #1 需求变更：工具产出文件不上时间线；图片仍带 `images`） |
| `tool/ptc-dispatch-start` | PTC 子调用开始（v3.4，issue #68）：`{ turn?, step?, rootCallId?, parentCallId, callId, name?, status: "running", summary? }`；`callId` 即内核对 `subCallId`，**不下发** `arguments` 原文 / `meta`；仍属 debug-only（见 §6.24.1） |
| `tool/ptc-dispatch` | PTC 子调用落定（v3.4，issue #68）：同上 + `{ status: "success" \| "failed", isError, text?, error? }`；`text` 仅失败时下发且只含安全错误码（`error.code` 优先、缺省 `error.name`，≤500），`error` 仅 `{ name, code }`；超 50 子调用时下发最小 `truncated: true` 通知（见 §6.24.1） |
| `turn/start` | `{ turn: number }` |
| `turn/end` | `{ turn: number, reason: object }` |
| 其他 | 保留 `type`、`seq` 和详情指针；调试模式展开无损数据 |

**控制帧**：连接建立后立即 `data: {"type":"hello","serverTime":...,"capabilities":{"eventTimeline":{...},"turnOutline":{...}}}`；每 25s `: ping` 注释行。bootstrap 同样返回这两项能力；`turnOutline` 与 bootstrap 同判据、同形状（见 §6.18），客户端应按能力协商而不是按版本号猜测。
**错误语义**：鉴权失败在连接建立阶段以 `401` HTTP 状态返回（EventSource 会触发 error 事件，客户端转登录态）。

### 3.6b SSE 帧类型汇总（v2.3+ 扩展）

除 3.6 的 `session/event` 外，SSE 还会推送：

| type | 说明 |
|---|---|
| `session/context` | `{ sessionId, contextWindow }`——模型上下文窗口（`request/context` 事件，PC 端圆环同源） |
| `agent/status` | `{ agentId, sessionId, status, child }`——running / waiting / idle；`sessionId` 为去 `session:` 前缀的会话 id，`child` 标记子代理会话（v2.7.2 起携带后两字段） |
| `notifications/changed` | 通知记录增删（如移动端删除后），客户端刷新列表与角标 |
| `mobile/notify` | `{ notification: { id, kind, sessionId, title, detail, time } }`——插件"真结束"判定后推送的通知（completed / failed / needs-answer），桌面宠物/App 与通知中心同源渲染（v2.7.2） |
| `mobile/frame` | 内核瞬态帧（问询/审批）。`frame` 字段为 `question/requested`（含 `rpcId`、`questions[]`）、`question/resolved`（`questionRpcId`）、`approval/requested`（`rpcId`、`approvalId`、`toolName`、`reason?`）、`approval/resolved`（`approvalId`）。**App 断线重连时服务端补发挂起的待答帧**（`pendingFrames` 回放） |
| `mobile/queue` | `{ sessionId, rows: [{ id, text, placement }] }`——内核队列快照（`agent/inbox/spliced` 即时镜像，v3.0.2）：认领/删除/编辑实时反映，App 端 dock 以此为权威源（`placement`: `queued` / `steering` / `context`，与 GET /queue 同款形状）；断线重连时 mux 回放当前队列 |

客户端应按 `type` 分派；未知 type 使用通用事件卡保留顺序，并在调试模式通过详情指针展开（前向兼容）。
### 3.7 GET /m/qr.png

**查询参数**：`text`（必填，二维码内容，URL 编码）。无 `text` → `400`。 **响应**：`200 image/png`（qrcode 包生成，尺寸 512，纠错级别 M）。
## 4. 错误码汇总
| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `bad-request` | JSON 解析失败 / 缺参 / 参数类型错误 |
| 400 | `empty-text` | send 的 text 为空 |
| 401 | `auth-required` | 未提供有效凭证 |
| 401 | `bad-token` | 登录口令错误 |
| 429 | `rate-limited` | 登录失败超限（v2.6，仅 authToken 启用时；响应带 `Retry-After` 头，默认 60s 后恢复） |
| 404 | `not-found` | 未知路径 |
| 404 | `session-not-found` | 会话不存在 |
| 404 | `event-not-found` | 事件不存在、属于内部/敏感类型，或不在移动端 Visible timeline |
| 413 | `event-detail-too-large` | 单个无损详情超过 8 MiB 上限 |
| 405 | `method-not-allowed` | 方法不支持（GET 端点收到 POST 等） |
| 503 | `no-live-agent` | 无运行中 agent |
| 503 | `agents-unavailable` | agents 服务不可用 |

## 5. 版本兼容策略

- 端点仅追加、不破坏性修改；`event` 摘要格式允许增加字段，禁止删除/重命名既有字段。
- 前端与后端同包发布（单文件页面由插件自身服务），无跨版本部署问题。
## 6. 移动端新增端点（Phase 1，v2.0）
> 全部要求鉴权（与既有端点一致）；写操作遵循与 PC 端相同的确认语义（如 Full Access 风险确认由客户端先行，服务端在参数中携带确认标记）。
### 6.1 端点总表

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/m/api/catalog` | 模型目录 + 推理强度 + 权限预设 + Agent 预设（全部枚举，一次拉取） |
| GET | `/m/api/session-config` | 当前会话配置（模型/推理强度/权限/预设） |
| POST | `/m/api/session-config` | 更新当前会话配置 |
| POST | `/m/api/sessions` | 新建会话（preset 参数） |
| GET | `/m/api/notifications` | 通知列表（未读/已读） |
| POST | `/m/api/notifications/read` | 标记已读（单条/全部） |
| POST | `/m/api/notifications/delete` | 删除通知记录（单条/批量/全部，v2.3） |
| GET | `/m/api/actions` | 插件动作清单（实时） |
| POST | `/m/api/actions/:id/invoke` | 执行插件动作 |
| GET | `/m/api/usage` | 会话 token 用量统计（v2.1） |
| GET | `/m/api/workspaces` | 已注册工作区（新建会话默认目录，v2.1） |
| GET | `/m/api/directories` | 目录浏览（盘符/子目录，v2.1；v3.1.1 根视图响应新增 `sep` 字段；issue #45 可选 `includeHidden=1` 显示点开头条目，`.git` 永不返回） |
| POST | `/m/api/directories` | 新建文件夹（v2.1） |
| GET | `/m/api/diagnostics` | 环境诊断（服务端端点实测，v2.1） |
| GET | `/m/api/balance` | DeepSeek 官方余额（服务端代查，v2.1） |
| GET | `/m/api/account-usage` | 用量与额度（服务端代查，v3.2） |
| GET | `/m/api/turn-outline` | 会话轮次大纲（只读；完整阶梯的轮次摘要，轮次导航） |
| GET | `/m/api/qr-config` | 桌面二维码数据（loopback only，v2.1） |
| POST | `/m/api/defaults` | 修改默认 Agent/权限预设（v2.1） |

> **路径风格约定（v3.1.1，issue #5）**：`GET /m/api/directories?path=`、`POST /m/api/directories {path}` 与
> `POST /m/api/sessions {cwd}` 的路径允许按客户端平台习惯传分隔符（Windows `\` / WSL·Linux·macOS `/`）；
> 服务端会归一化为**当前平台**分隔符后读盘/建夹/建会话（旧版 App 在 WSL 上拼出的 `/\home` 也能命中真实目录）。
> 根视图响应（`path` 为空）携带 `sep`（服务端真实分隔符），新版 App 据此拼接子目录，不再按 Windows 习惯硬编码 `\`；
> 该字段为纯增量，旧版 App 忽略即可。

> **隐藏条目（issue #45，纯增量）**：`GET /m/api/directories?path=<非空>&includeHidden=1` 时，
> 点开头的目录与文件会同时出现在 `dirs` / `files` / `fileEntries` 三条列表里（排序规则不变）；
> 缺省或 `includeHidden` 不是 `1` 时保持旧行为，全部隐藏点开头条目。无论是否 `includeHidden`，
> 名称恰为 `.git` 的条目（**文件或目录**）永远不返回，列表不提供进入其内部的入口。
> 这只是列表可见性规则，显式路径仍可读取 `.git/config`，不构成访问控制。
> 根视图（`path` 为空）与 `POST /m/api/directories` 不受该参数影响；
> `/m/api/files` 下载/预览通道对隐藏文件与普通文件一视同仁（可按普通文件路径读取隐藏文件）。
> 隐藏判定只看**名字是否以 `.` 开头**（Windows 隐藏属性不在本次范围）；显式按路径发起的列表/读取
> 仍沿用既有只读信任模型，本参数只影响目录列表的可见性。旧客户端不传该参数即可，契约纯增量，
> 不新增 capability 位。

### 6.2 GET /m/api/catalog

返回 PC 端真实枚举（单一事实源，客户端不硬编码）：
```json
{
  "ok": true,
  "models": [
    { "provider": "deepseek-official", "id": "deepseek-v4-flash", "name": "DeepSeek-V4-Flash",
      "reasoning": { "efforts": [{ "id": "off", "name": "Off" }, { "id": "high", "name": "High" }], "defaultEffort": "high" } },
    { "provider": "openai-codex", "id": "gpt-6-luna", "name": "GPT-6-Luna",
      "reasoning": { "efforts": [{ "id": "low", "name": "Low" }, { "id": "xhigh", "name": "Xhigh" }] } }
  ],
  "reasoningEfforts": ["off", "high", "low", "xhigh"],
  "permissionPresets": [
    { "id": "read-only", "name": "Read Only", "description": "只读 · 拒绝一切写入操作" },
    { "id": "workspace-write", "name": "Workspace Write", "description": "仅工作区内读写 · 危险操作前询问" },
    { "id": "danger-full-access", "name": "Danger Full Access", "description": "完全访问 · 可执行任何操作" }
  ],
  "agentPresets": [
    { "id": "standard", "name": "标准模式", "description": "功能完整的编码 Agent：文件编辑、Shell、文件与网页检索、Skills、计划、目标、子代理和工作流" },
    { "id": "code", "name": "PTC 模式", "description": "—" },
    { "id": "minimal", "name": "极简模式", "description": "—" },
    { "id": "cordis", "name": "创造模式", "description": "—" }
  ],
  "defaults": {
    "provider": "deepseek-official",
    "model": "deepseek-v4-flash",
    "reasoningEffort": "max",
    "permissionPreset": "workspace-write",
    "agentPreset": "standard"
  }
}
```

`models[].reasoning` 来自内核模型目录，只对该模型有效；没有该字段表示不支持显式强度。`reasoning.defaultEffort` 可以缺省，此时由提供商决定；`off` 是具体等级而不是“跟随默认”。顶层 `reasoningEfforts` 是历史上的跨模型并集，仅为兼容已发布接口保留；客户端必须按当前模型取能力，不能据此绘制或验证当前模型的按钮。`defaults.provider/model` 是部署默认模型，不是第一个活动会话上次使用的模型。目录通常缓存 15 秒；选择失败后的 `GET /m/api/catalog?refresh=1` 绕过缓存，以便重新展示该模型的最新能力。权限、Agent 预设来自对应宿主服务。
### 6.3 GET /m/api/session-config

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "config": {
    "provider": "openai-codex",
    "model": "gpt-6-luna",
    "reasoningEffort": "low",
    "permissionPreset": "workspace-write"
  }
}
```

模型身份与强度读取自 `session/control` 的 `modelSelection.next`（待生效选择），不是可能滞后的 `lastUsed`。内核可能把省略的 effort 具体化为模型默认值，因此返回 `low` 不代表用户曾显式选择了 `low`。

### 6.4 POST /m/api/session-config

**切换模型**（provider、model 必须成对提供，省略强度即使用新模型默认值）：

```json
{ "sessionId": "session-abc", "provider": "openai-codex", "model": "gpt-6-luna" }
```

**只改强度**：`{ "sessionId": "session-abc", "reasoningEffort": "high" }`；**回到模型默认**：`{ "sessionId": "session-abc", "resetReasoningEffort": true }`。两者不可同时提交。服务端使用同一次 `next` 的 provider/model；若 `next` 不可确认，返回 `409 model-selection-unavailable`，不拿 `lastUsed` 或 DeepSeek 兜底。**限定条件（2026-10-04 补充）**：该保证针对**已挂载**会话；对休眠会话，插件在按 `next` 取值后仍会执行 `Object.assign(config, foldFromEvents(events))`，而折叠函数恒返回全部字段（无匹配事件时为 `undefined`），会覆盖投影值——两者同源（都来自 `model/selection` 事件），但休眠会话可能因此报不出 effort。真正的修复方向是核心侧 `readSession` 走 restore 构造路径（见 issue #20）。不支持该模型的显式强度由内核拒绝，目录过期时客户端应刷新目录并显示错误，不静默降级。

- `permissionPreset` 为 `danger-full-access` 时 `confirmDanger` 必须为 `true`，否则 `400 { "error": "risk-confirmation-required" }`（与 PC 端 Full access 需显式确认风险一致）。
- 权限写入走 PC 端同一路径（`permission/preset` + sandbox/approval 旋钮事件）。
- 模型选择会产生内核 `model/selection` 事件；`404 session-not-found` 通常表示会话不存在——但**请求带 `permissionPreset` 时，休眠（未挂载）会话也会 404**：权限预设需要本地 Session 对象才能 `applyPermissionPreset`，无法像模型/强度那样经内核 `selectModel` 对持久化会话生效（2026-10-04 补充）。
### 6.5 POST /m/api/sessions（新建会话）

**请求**：
```json
{
  "preset": "standard",
  "provider": "openai-codex",
  "model": "gpt-6-luna",
  "reasoningEffort": "high",
  "permissionPreset": "workspace-write"
}
```

- `preset` 未传时使用服务端 Agent 预设默认值；`provider` 和 `model` 必须一起指定，未指定时采用内核部署默认选择（包含部署默认强度），不沿用现有会话配置。主动指定新模型而省略 `reasoningEffort` 时采用该模型默认强度；具体等级由内核校验。
- 新建页模型草稿不修改已有会话。服务端先确定完整模型身份，再创建 agent 并选择模型；选择或附加配置失败时清理新建会话，返回错误而非假报成功。
**响应**：`200 { "ok": true, "sessionId": "session-xyz", "agentId": "session-xyz" }`——客户端随后即可 `POST /api/send` 或订阅 SSE 该会话。
### 6.6 GET /m/api/notifications

通知由服务端从会话事件流**聚合**（不新增存储）：

```json
{
  "ok": true,
  "unread": 2,
  "items": [
    { "id": "n-1", "kind": "needs-answer", "sessionId": "session-abc", "title": "需要你回答", "detail": "发现 214 个重复文件，是否删除以释放空间？", "time": 1750000000000, "unread": true },
    { "id": "n-2", "kind": "completed", "sessionId": "session-abc", "title": "任务完成", "detail": "备份配置到 E 盘（耗时 4 分钟）", "time": 1750000000000, "unread": true },
    { "id": "n-3", "kind": "failed", "sessionId": "session-def", "title": "任务失败", "detail": "日志分析任务执行失败，已自动重试", "time": 1750000000000, "unread": false }
  ]
}
```

- `kind`：`completed`（turn/end 正常）、`needs-answer`（等待人类决策——从审批/提问相关事件推导，Phase 1 实现时验证语义）、`failed`（turn/end 异常/aborted）。
- **未读状态持久化**：插件在 settings 域保存已读 id 集合（`ctx.settings`），服务重启不丢。
- 排序：时间倒序；上限 100 条。
### 6.7 POST /m/api/notifications/read

```json
{ "ids": ["n-1", "n-2"] }
```
或 `{ "all": true }`。响应 `200 { "ok": true }`。
### 6.7b POST /m/api/notifications/delete（v2.3）

```json
{ "ids": ["n-1", "n-2"] }
```
或 `{ "all": true }`。删除移动端通知镜像中的记录（不影响 PC 端自己的通知中心）；不设墓碑——后续新事件仍会正常生成新通知。删除后经 SSE 广播 `notifications/changed` 帧，客户端刷新列表与未读角标。响应 `200 { "ok": true }`。
### 6.7c POST /m/api/respond（v2.3，问询/审批弹窗）

回答内核人类问询（`ask_user_question` 工具）或权限审批。插件经 `apiProxy.respond` 回写，**与 PC 端 GUI 完全同一 pending 通道与校验**（`matchesQuestions`、审批决策等由内核把关）：

**问询**（`kind: "question"`，answers 顺序与提问一致、每问必答）：

```json
{ "kind": "question", "rpcId": "<frame 携带的 rpcId>", "sessionId": "session-abc",
  "answers": [ { "id": "q1", "selected": ["方案A"] }, { "id": "q2", "selected": [], "custom": "先跳过" } ] }
```

- 单选：`selected` 至多 1 项；给了 `custom` 则 `selected` 必须为空（二选一）。
- 多选：`selected` 多项；`custom` 可与之并存。
- `selected` 必须是提问声明的选项 label。

**审批**（`kind: "approval"`）：

```json
{ "kind": "approval", "rpcId": "...", "sessionId": "session-abc", "approvalId": "a-1", "outcome": "allowed-once" }
```

- `outcome`：`allowed-once` | `rejected`。

**取消**（`kind: "cancel"`）：内核收到 cancelled，agent 按 `ASK_CANCELLED` 继续。

响应：`200 { "ok": true, "accepted": true }`；`accepted: false` + `reason`（如 `not-pending`，PC 端已先回答）。

**SSE 帧**：`question/requested`（含 `questions[]`）、`question/resolved`、`approval/requested`（toolName/reason）、`approval/resolved`，经 `mobile/frame` 帧推送；App 断线重连时服务端补发挂起的待答帧。
### 6.8 GET /m/api/actions

**动作契约 v0.1**（可选能力，插件不注册则返回空数组，客户端隐藏动作区）：

```json
{
  "ok": true,
  "actions": [
    { "id": "fs-cleanup", "title": "清理磁盘", "icon": "trash", "fields": [ { "key": "target", "label": "目标目录", "placeholder": "如 F:\\资料" } ] },
    { "id": "test-run", "title": "跑测试", "icon": "zap", "fields": [] }
  ]
}
```

- 服务端注册表：`ctx.mobileActions.register({ id, title, icon, fields?, handler })`——id 冲突抛错（Cordis 语义）；插件卸载随 fiber dispose 自动移除。
- `icon` 限定为移动端内置图标库的 id（不允许插件自带 UI/图标）。
- `fields`：v0.1 仅支持 `text` 类型字段。
### 6.9 POST /m/api/actions/:id/invoke

**请求**：`{ "args": { "target": "F:\\资料" } }`

- 服务端校验注册表存在与参数类型，调用 `handler(args)`（跑在电脑端）。
- 执行结果**不直接返回**（可能长任务）：`200 { "ok": true, "accepted": true }`；后续进展经 SSE 会话事件回流（动作应通过既有消息/工具通道呈现）。
### 6.10 GET /m/api/qr-config（桌面二维码数据，v2.1）
**仅电脑本机可访问**（TCP 层 socket 来源，仅 loopback 可访问；否则 403 `loopback-only`）—— 桌面 dsh 设置页客户端模块用它生成「连接移动端设备」二维码。
> v2.6.0：`/m/qr.png`（二维码图片渲染，供设置页 `<img>` 使用）同样收口——Host 校验 + loopback 来源，非本机 403。
**响应**：`{ "ok": true, "urls": ["http://192.168.1.100:3080/m", ...], "token": "<authToken>", "path": "/m" }`

> v3.0.0：`lanBridge.enabled` 且监听成功时，`urls` 首选为桥地址（`http://<电脑局域网IP>:<lanBridge.port>/m`，端口默认 3080）；绑定失败自动回退 webserver 地址（不指向死端口）。

二维码内容格式：`DSHREMOTE|<地址>|<口令>`（地址取 `urls` 中首个非回环项，不含 /m 尾巴）。App 扫码解析后自动配置连接。
### 6.11 POST /m/api/defaults（修改默认配置，v2.1）
修改**默认 Agent 预设 / 默认权限预设**（作用于之后新建的会话），与 PC 端设置页同一写入通道（走 `/api` 调 `settings.update`，不在 HTTP 回调直接调 settings 服务）。
**请求**：`{ "agentPreset": "code", "permissionPreset": "workspace-write" }`（两者均可选）

**响应**：`200 { "ok": true }`；失败 `400 { "error": "update-failed", "detail": "<原因>" }`

### 6.11b GET /m/api/diagnostics（宿主能力自检字段）

环境诊断在 `checks` 下提供宿主兼容自检（ADR 0017，**纯增量字段，旧 App 忽略即可**）：

- `checks.hostCapabilities`：逐项三态 `ok` / `drift` / `missing`。`drift` = 能力语义漂移（服务在、调用不报错、成员形状或实参语义已变）。包含 `jobs.callerShape`、`jobs.eventsApi`、`settings.read`、`gateway.wireStream`、`gateway.eventsPeer`（issue #34，0.2.1 的进程内 Peer 来源）、`permissionPresets.apply`、`permissionPresets.catalog`、`workspaceRegistry.stateWrite`。
- `checks.hostCapabilityReasons`：仅对 `drift` 项给出的允许清单原因码（如 `settings.read` 的 `settings-get-threw`；`gateway.eventsPeer` 的 `gateway-peer-source-missing`）。
- `checks.hostGeneration`：插件实际走到的代际路径——`jobsCaller`（`sessionId` / `agent`）、`settingsRead`（`describe` / `get`）、`wireStreamArgs`（`controlArg` / `legacyArg`）、`eventsPeer`（`createPeer` / `operatorPeer` / `legacy` / `none` / `unknown`）。
- `checks.remoteEvents` / `checks.approvalMode`：`$events` 双端审批通道是否就绪与实际生效的审批呈现策略。

详见 `docs/09-compatibility.md` §2.5/§2.6。

### 6.12 错误码补全
| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `risk-confirmation-required` | 选 danger-full-access 未带 confirmDanger |
| 400 | `invalid-preset` | preset 不在目录内 |
| 404 | `action-not-found` | 动作 id 未注册 |
| 503 | `action-busy` | 同一动作并发执行限制（v0.1 可先不做） |

### 6.13 模型提供商（v2.6，与 PC 端「设置 → 模型」同一配置通道）
> 全部端点需鉴权；密钥只写不读（响应不含密钥本身）。

**GET `/m/api/llm-providers`** — 提供商列表（live + dormant）
```json
{ "ok": true, "providers": [
  { "id": "deepseek-official", "name": "DeepSeek", "dormant": false,
    "settingsNs": "llm-deepseek", "settingsPath": [],
    "baseURL": "https://api.deepseek.com", "apiKeyRef": "DEEPSEEK_API_KEY",
    "keyConfigured": true, "keyWritable": true, "catalogModels": [{"id":"deepseek-v4-pro","name":"DeepSeek-V4-Pro"}] },
  { "id": "anthropic", "name": "anthropic", "dormant": true, "settingsNs": "…", "baseURL": null, "keyConfigured": false }
]}
```
- dormant = 配置目录已声明但未激活（配好 baseURL/密钥即生效）；37 个内置 dormant 提供商（anthropic/openai/google/groq 等）
- `apiKeyRef` 为凭据引用名（如 `DEEPSEEK_API_KEY`），**非密钥本身**；`keyConfigured` 指示是否已存

**POST `/m/api/llm-providers/probe`** — 探测端点模型列表
```json
请求: { "settingsNs": "llm-deepseek", "baseURL": "https://…", "apiKey": "可选", "protocol": "可选" }
响应: { "ok": true, "models": [{"id":"…","name":"…","contextWindow":…}], "fallback": true }
```
- 优先内核 `discoverModels`；内核未注册模型探测时回退 OpenAI 兼容 `GET {baseURL}/models`
- 凭据一次性使用，不存储；仅允许探测配置目录声明的命名空间

**POST `/m/api/llm-providers`** — 保存提供商配置
```json
请求: { "provider": "deepseek-official", "settingsNs": "llm-deepseek",
        "baseURL": "https://…", "apiKey": "可选（留空不修改）", "removeKey": false }
响应: { "ok": true, "provider": "…", "apiKeyRef": "…", "keyConfigured": true }
```
- 经 `settings.mutate` 写配置 + `credentials.set` 存密钥（引用派生规则与 PC 端一致：`<PROVIDER>_API_KEY`）
- 仅允许写入配置目录声明的命名空间（`400 unknown-provider`）；`removeKey: true` 清除已存密钥

### 6.14 会话工具（v2.7：任务 / 子代理 / 目标，PC 端 GUI 同源）
> 全部端点需鉴权；数据与 PC 端「任务 / 子代理 / 目标」同一内核服务，手机只读 + 简单操作。

**GET `/m/api/jobs?sessionId=可选`** — 会话后台任务列表（不传 sessionId 返回全部）
```json
{ "ok": true, "sessionId": "…", "jobs": [
  { "id": "…", "kind": "task", "label": "…", "status": "running",
    "startedAt": 1786987923387, "finishedAt": 1786987923387 }
]}
```
- 状态：`running / stopping / completed / failed`；任务视图与 SSE `session/jobs` 帧同源
- 会话不存在 `404 session-not-found`；jobs 服务不可用 `503 jobs-unavailable`

**POST `/m/api/jobs/kill`** — 取消任务
```json
请求: { "sessionId": "可选", "jobId": "…" }
响应: { "ok": true }
```
- 映射内核 `jobs.kill(jobId, agent, reason)`；失败 `400 job-kill-failed`

**GET `/m/api/subagents?parentSessionId=…`** — 子代理列表（按父会话）
```json
{ "ok": true, "parentAvailable": true, "catalogDegraded": true, "subagents": [
  { "id": "…", "kind": "child", "status": "running", "title": "…", "createdAt": 1730000000000 }
]}
```
- 目录来源按优先级取：① 宿主持久目录 `ctx.subagents.listChildren(parentSessionId)` → ② 持久化枚举（父会话休眠/归档时入口不消失）→ ③ 会话注册表派生。
  **不调用 `subagents/list` Remote 端点**——该端点在宿主 0.2.0 已被删除
- `kind`：`child`（普通子代理）或 `diagnostic`（目录 `mode: "unknown"` 的不受支持条目，此时 `status` 为原因 `unsupported`）
- `status`：活 agent 的 AgentStatus 映射（`running`/`inactive`）或 diagnostic reason
- `createdAt` 可选，用于排序；`catalogDegraded: true` 表示来源 ②/③ 不完整，客户端据此区分"确实没有子代理"与"目录读不到"
- 缺参数 `400 parentSessionId-required`；三条路径都取不到会话 `404 session-not-found`

**POST `/m/api/subagents/interrupt`** — 中断子代理
```json
请求: { "parentSessionId": "…", "childSessionId": "…" }
响应: { "ok": true }
```
- 映射内核 `subagent.interrupt`（payload `{ parentSessionId, childSessionId, mode: "continuable" }`）

**GET `/m/api/goal?sessionId=…`** — 当前目标（无目标返回 `{ "goal": null }`）
```json
{ "ok": true, "goal": { "id": "…", "revision": 1, "objective": "…",
  "phase": "active", "maxGoalRounds": 256, "roundsStarted": 0,
  "createdAt": 1786987923387, "updatedAt": 1786987923387, "activation": "armed" } }
```
- `phase`: active / paused / blocked / complete；blocked 时含 `blockedReason`（如轮次耗尽）
- 无会话 `503 goal-unavailable`

**POST `/m/api/goal`** — 创建 / 暂停 / 继续 / 完成
```json
请求: { "action": "create|pause|resume|complete", "sessionId": "…",
        "objective": "create 必填", "maxGoalRounds": "create 可选" }
响应: { "ok": true }
```
- 映射内核 goal RPC（契约一致：create 需 `sessionId + objective`；pause/resume/complete 需 `sessionId + ref`，ref 由插件经 `goals.get(agent)` 自动取得）
- 缺参 `400 sessionId-required / objective-required`；无当前目标 `400 no-active-goal`；非法 action `400 bad-action`

### 6.15 斜杠命令（v2.8.0 引入 / v2.8.2 适配内核 0.1.1-rc.2）

**GET `/m/api/commands?sessionId=…`** — 命令目录（对齐内核 `ctx.commands`）
```json
{ "ok": true, "commands": [
  { "name": "goal", "description": "set or view the goal for a long-running task",
    "input": { "hint": "[<objective>|clear|edit <objective>|pause|resume]", "attachments": true } }
] }
```
- 命令条目：`name` / `description` 必填；`input`（`hint` / `attachments`）可选，有则返回——**原样透传**内核 `commands.list()` 的描述符，插件不改写字段
- ⚠️ **字段名是 `attachments`，不是 `images`**（内核 `dsh-commands` 与 PC 端客户端均判定 `input.attachments === true`）。本文档 2026-10-04 修正，此前误写为 `images` —— 按旧文档实现会永远读不到该标志
- `commands` 服务未注册（无 dsh-commands host 服务）→ `200 { ok, commands: [], unavailable: true }`（App 端弹「无可用命令」，不硬 503）
- 会话不存在 → `404 session-not-found`；缺 `sessionId` → `400 bad-request`。**GET 要求会话已挂载**（`agents.get(sessionId)` 命中）：休眠/未挂载会话返回 404 —— 这与 `/send`（会先自动 resume 再发）不同，客户端不能假设"能发消息就一定能列命令"

**POST `/m/api/commands`** — 执行斜杠命令
```json
请求: { "sessionId": "…", "line": "/goal" }
响应: { "ok": true, "result": { "commandId": "cmd-…", "result": { "kind": "success", "text": "…" } } }
```
- 映射内核 `commands.execute(agent, line, images, signal)`（0.1.1-rc.2 四参签名；本插件 `images` 恒为空数组，`signal` 为 15s 超时中止；2.8.1 的旧三参调用会把 AbortSignal 误传 images 槽，已改正）
- 缺 `sessionId` → `400 missing-sessionId`（注意与 GET 的 `bad-request` **不同码**）；`line` 必须以 `/` 开头（否则 `400 bad-request`）；未知/畸形命令 `404 command-not-found`；服务未注册 `503 commands-unavailable`（带 detail）；服务在而会话不存在 `404 session-not-found`（与 GET 拆分语义一致）
- **会话必须已挂载**：`agents.get(sessionId)` 未命中即 404。休眠会话需先经 `/send` 唤醒，否则命令无法执行（与 `/send` 的自动 resume 语义不同）
- `commands.execute` 外层套 `AbortSignal.timeout(15000)`：15s 是**整个命令**的上限。`/compact` 之类会等一次完整的 LLM 摘要，长会话可能超时 → `504 commands-execute-failed`；客户端此时**不能断言失败**（结果未知）
- `result` 为内核 settle 对象（`commandId` + `result.{kind,text}`），与 PC 端一致

### 6.16 GET /m/api/account-usage（用量与额度，v3.2）

服务端并发查询三个固定来源，凭据只在电脑端解析和使用；手机端只接收成功来源的脱敏投影。默认使用电脑进程内 60 秒快照；详情页顶部刷新使用 `?refresh=1` 绕过快照并发起一轮新的查询（2 秒内重复刷新受保护）。来源固定按 DeepSeek → Codex → OpenCode Go 排列，未配置/未登录来源不返回，已配置但本次查询失败的来源也不返回。

```json
{
  "ok": true,
  "fetchedAt": "2026-08-30T12:00:00.000Z",
  "availableCount": 3,
  "failedCount": 0,
  "sources": [
    { "id": "deepseek", "title": "DeepSeek", "kind": "balance",
      "amount": "12.50", "currency": "CNY", "available": true },
    { "id": "codex", "title": "Codex", "kind": "quota",
      "account": { "displayName": "Personal", "maskedEmail": "p***@example.com" },
      "windows": [
        { "window": "5h", "remainingPercent": 72, "resetAt": "2026-08-30T13:00:00.000Z" },
        { "window": "weekly", "remainingPercent": 64 }
      ],
      "credits": { "unlimited": false, "balance": "8.00" },
      "individualLimit": { "limit": "100", "used": "28", "remaining": "72", "remainingPercent": 72 }
    },
    { "id": "opencode-go", "title": "OpenCode Go", "kind": "quota",
      "windows": [
        { "window": "5h", "remainingPercent": 91 },
        { "window": "weekly", "remainingPercent": 83 },
        { "window": "monthly", "remainingPercent": 76 }
      ]
    }
  ]
}
```

- Codex 通过 `dsh-codex-connect` 的 `OpenAICodexCredentialStore`、`openAICodexAuthStatus` 与 `readOpenAICodexRateLimits` 查询同一份当前活动账户快照；若 Codex 配置启用代理，额度请求复用其 `OpenAICodexProxyManager`，代理不可用时不直连；不读取/复制 OAuth 文件，不返回 token。
- OpenCode Go 优先读取 `llm-pi-ai` 的 `opencode-go.apiKeyEnv`，其次读取 `llm-pi-ai/opencode-go` API-key record，再回退 `OPENCODE_GO_API_KEY` / `OPENCODE_API_KEY`；请求固定发送到官方 `GET https://opencode.ai/zen/go/v1/usage`，不接受任意 baseURL。`percent` 转换为 `remainingPercent = 100 - percent`，`rate-limited` 窗口仍保留并标记 `limited: true`。
- `failedCount` 只统计“已配置但本次查询失败”的来源；未配置来源不算失败。`failedCount > 0` 时 App 显示汇总提示，不显示失败来源细节。
- 查询快照在电脑进程内缓存 60 秒并共享并发请求；手动 `refresh=1` 的连点在 2 秒内复用快照；不写手机或电脑持久化文件。配额窗口不相加，有限 Credits 和个人消费上限分别展示。
- HTTP 错误只返回通用 `502 account-usage-failed`（单来源失败不会使整体请求失败）。

**桌面宠物面板消费语义（v3.2）**：原生桌面宠物面板把本端点当作「展开时按需读取」的快照——每次展开面板最多触发一次查询（客户端 2 分钟节流，不并入面板打开期间的 5 秒轮询，也不做后台周期轮询）；成功快照在进程内保留，失败时沿用旧值并标注相对时间；投影不可用（旧插件 404 / 未配置 / 全部失败）时，面板整体降级为原有的单行 DeepSeek 余额。面板按「一个来源一行」渲染：金额来源保留文字（CNY 优先），配额来源只显示主 bucket 窗口的细条与颜色、不出百分比数字，每个进度条上方居中显示窗口短标签（5h / 每周 / 每月，与详情页窗口语义一致）；附加 bucket（服务端命名的 `名称 · 5h`）与账户身份不出现 overlay 面板，详情页仍是完整信息入口（`displayName`/`maskedEmail`、Credits、个人消费上限、重置时间）。

### 6.17 文件传输（v3.1.2，B站 csborbbnc 反馈）

**GET `/m/api/files?path=…`** — 下载电脑文件
- 响应：`200` 文件流（`content-type` 按扩展名推断、`content-disposition: attachment` 带 UTF-8 文件名）；路径不存在 → `404 file-not-found`；非普通文件 → `400 not-a-file`；缺 `path` → `400 bad-request`
- 与目录选择器（§6.1）同信任模型：口令鉴权 + 现有限流，路径由手机显式指定
- 支持 `HEAD`、单区间 `Range`、`ETag`、`If-None-Match`；有效区间返回 `206 + Content-Range`，越界返回 `416`。
- 续传携带 `Range: bytes=N-` 与此前保存的 `If-Range: <ETag>`。只有标记一致才返回区间；不一致、弱标记或日期标记均返回完整 `200`，客户端截断旧文件后从头写。
- App 在私有支持目录保留断点，按地址、API 路径和认证身份的摘要隔离；不持久化口令。恢复时核对 ETag、实际本地长度、完整区间和最终总长度；旧宿主缺标记时从头下载。
- 暂停、断网、锁屏中断和进程退出后，可从聊天页下载入口继续；保存到系统下载目录失败时保留已下载文件以便重试保存。恢复列表最多八项，七天后在下次打开该宿主的下载入口时清理，可手动删除。
- Android 用户发起下载后启动专用 `dataSync` 前台服务，通知提供进度与暂停，完成、失败或暂停后退出；服务不可用或通知关闭时明确退回前台下载。服务与宠物/提醒保活的开关独立，不传递 URL、口令或远端路径。
- Android 15+ 的累计后台时限由系统管理；`onTimeout` 立即停止服务并通知 Dart 暂停，保留私有断点，不通过重启服务绕过预算。Doze、ROM 冻结或进程终止仍可能中断网络，不承诺锁屏无限连续下载；真实后台验收单独记录。

**POST `/m/api/files/upload`** — 上传文件到电脑（写会话工作目录）
```json
请求: { "sessionId": "…(可选)", "name": "README.md", "data": "<base64>" }
响应: { "ok": true, "path": "F:\\DSH-Outpost\\README.md", "bytes": 1234 }
```
- 目标目录：`sessionId` 对应 agent 的工作目录 → 缺省回退第一个注册工作区根；无法确定 → `503 no-workspace`
- `name` 不合法（含 `\ / : * ? " < > |`、`.`/`..`/超 255）→ `400 invalid-name`；body 上限 64MB → `413 payload-too-large`

### 6.18 GET /m/api/turn-outline（轮次大纲，轮次导航）

> 只读端点：把宿主 `turnOutline` 投影（电脑端刻度轨消费的同一份轮次摘要）**薄透出**为移动端契约。插件只做投影读取与形状稳定化，**不自己折叠会话日志**——轮次边界与预览文字只有宿主一个权威来源，避免桌面端与手机端在边界条件上出现两种答案。不改变会话内容/轮次边界，不写任何持久状态，不新增会话事件类型。

**查询参数**：`sessionId`（必填；缺 → `400 bad-request`）。

**响应 200（可用态）**

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "state": "available",
  "asOfSeq": 12873,
  "turns": [
    { "turn": 1, "seq": 2048, "prompt": "帮我跑一下测试", "response": "测试结果……" },
    { "turn": 2, "seq": 5121, "prompt": "", "response": "纯命令轮的回复" }
  ],
  "truncated": false,
  "dropped": 0
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `state` | string | `available` / `empty` / `capability-missing` / `read-failed`（四态见下） |
| `asOfSeq` | number \| null | 该投影快照对应的 durable 事件序号；`null` 表示无法确定 |
| `turns` | array | 轮次摘要，按 `turn` 升序；元素字段见下 |
| `turns[].turn` | number | 轮次号（从 1 开始） |
| `turns[].seq` | number | 该轮起始事件（`turn/start`）的 durable 序号，作定位锚点 |
| `turns[].prompt` | string | 该轮提示词预览；可能为空（纯图片/纯命令轮） |
| `turns[].response` | string | 该轮回复摘要；可能为空（该轮尚无回复） |
| `truncated` | boolean | 是否因体积上限截断（仅 `available` 有意义） |
| `dropped` | number | 被截掉的轮次数；未截断为 `0` |

**四态必须显式区分，空数组不得表示「没有轮次」**（同一份投影在不同宿主/会话上的语义差别很大）：

| `state` | 含义 | 客户端（刻度轨）行为 |
|---|---|---|
| `available` | 能力可用且该会话有大纲 | 与「已加载轮次」取并集画完整刻度；未加载轮次可点击（先跨页加载再定位） |
| `empty` | 能力可用，但该会话暂无大纲（新会话/投影尚未生成） | 退回「只用已加载轮次」的降级行为，不打扰用户 |
| `capability-missing` | 宿主未注册 `turnOutline` 投影单元，或没有投影感知观察面（**全局能力缺失**） | 同 `empty`；**不得**按宿主版本号自行推断 |
| `read-failed` | 读取失败；带稳定 `code` 与 `degraded: true` | 退回降级行为，在刻度轨可见时说明一次原因 |

`read-failed` 的稳定 `code`：

| `code` | 场景 |
|---|---|
| `turn-outline-timeout` | 有界等待超时（默认 5000 ms，见下「有界与截断」；从请求到达起算、**包含排队时间**） |
| `turn-outline-busy` | 冷折叠执行槽队列已满（并发 1、队列上限 8），立刻明确降级而不是无限排队 |
| `turn-outline-unavailable` | 宿主观察面无法回放完整日志（seeded 前缀校验缺陷等已知兼容问题） |

读取失败响应形状（HTTP 仍为 200；这是**明确的降级结果**，不是错误）：

```json
{ "ok": true, "sessionId": "session-abc", "state": "read-failed", "code": "turn-outline-timeout", "degraded": true, "turns": [] }
```

> 旧宿主路径（无投影感知观察面）返回的 `capability-missing` 形状为 `{ "ok": true, "sessionId": …, "state": "capability-missing", "turns": [] }`，可能不含 `asOfSeq`/`truncated`/`dropped`；客户端应按 `state` 分支，不依赖字段恒在。

**HTTP 错误码**：

| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `bad-request` | 缺 `sessionId` |
| 401 | `auth-required` / `bad-token` | 未提供 / 口令错误（见 §1） |
| 403 | `host-not-allowed` | Host 不在白名单（见 docs/04） |
| 404 | `session-not-found` | 会话**明确不存在**（只有这一种情况才 404） |
| 405 | `method-not-allowed` | 非 GET（HEAD 与其它 GET 端点一致：路由放行、无响应体） |
| 500 | `session-corrupt` / `event-read-failed` | 会话数据损坏 / 其它读取异常；错误响应不泄露主机路径或原始异常。**明确的超时/繁忙/已知兼容降级不走 5xx**，而是上表的 200 + `read-failed` |

**有界与截断**：

- **有界等待**：配置项 `turnOutlineTimeoutMs`（schema 默认 **5000 ms**；冷折叠单会话最坏实测 1.8 s，约 3× 余量）。截止后立即向仍连接的客户端回 `read-failed`；底层未结束的观察**不强行打断**（同步折叠不可中断），继续占住执行槽直到结束，迟到的投影 lease 随即释放、**不会回写成功**。客户端断开同样取消请求且之后不再写响应。
- **冷折叠串行**：并发 1 + 队列上限 8（3 路并发实测 RSS 峰值 831 MB、耗时近似叠加，故不允许无界并发）；队列满立刻回 `turn-outline-busy`。
- **按体积截断**：下发上限 **256 KB**（实测最大 77 KB / 288 轮、p99 29.5 KB）。从**最新**往回保留、至少保留 1 轮；超出部分丢弃并显式标 `truncated: true` / `dropped: N`——绝不静默截断，也不回空数组（回空数组会被读成「没有轮次」）。
- 实现使用宿主的投影感知观察面 `sessionQuery.observeSession(sessionId, { projectionMode: "all", signal })`；读到即释放 lease（不泄漏 prepared 会话 pin）。

**客户端消费约定（App 刻度轨）**：合并「已加载轮次」与 `turns`——按轮次号升序取并集，两边都有时保留已加载锚点、预览以已加载为准（仅本地为空时用大纲补齐，保证同一轮加载前后文字不跳变）；未加载轮次以短淡刻度呈现，点击后按 **200 条/页**有界跨页加载直至覆盖该轮起始序号，再走既有的按序号跳转定位；`empty` / `capability-missing` 不提示用户，`read-failed` / `truncated` 在刻度轨可见时说明一次。

**能力位**：`GET /m/api/bootstrap` 与 SSE hello 的 `capabilities.turnOutline` 与本节同一判据（见 §3.1、§3.6）：宿主真的注册了投影单元且观察面可用才 `supported: true`，否则 `supported: false`。客户端必须先读能力位再决定是否渲染未加载刻度。

### 6.19 Git 只读浏览接口（contractVersion 1.1.0，PR #63）

> 本节是移动端 Git 只读浏览的**自包含**接口说明（此前的只读 Git 实现没有写入本文档）。全部端点只读、要求鉴权，并且只允许读取「当前会话 `cwd` 所属、且位于已注册 DSH 工作区内的 Git 仓库」。响应不包含 host 发现的仓库绝对路径、remote URL 或作者邮箱；错误只返回稳定 `error` 码，不回传 provider 细节。唯一例外：`/git/file-history` 的 `reason: "path-invalid"` 会原样回显**客户端自己提交的** `path`，供客户端回填/纠错（见 §6.19.8）。对外契约版本 `contractVersion` 自本次起为 **`1.1.0`**：只做加法扩展，旧 App 与外部旧 provider 都不破坏。

**公共参数**：`sessionId`（必填）；除 `/git/capabilities`、`/git/repository` 外，其余端点还需要 `GET /m/api/git/repository` 返回的 `repositoryId`，它与会话绑定，跨会话/跨仓库复用会得到 `403 repository-not-authorized`。

| 方法 | 路径 | 用途 |
|---|---|---|
| GET | `/m/api/git/capabilities` | Git 只读能力与契约版本 |
| GET | `/m/api/git/repository` | 当前会话 cwd 解析出的仓库标识 |
| GET | `/m/api/git/branches` | 本地/远程分支列表 |
| GET | `/m/api/git/graph` | 一至五个 tip 之间的提交拓扑（分页） |
| GET | `/m/api/git/commit` | 提交详情 + 变更文件（分页） |
| GET | `/m/api/git/worktree` | 工作区快照（已暂存/未暂存/未跟踪） |
| GET | `/m/api/git/preview` | 单文件文本差异预览（有界） |
| GET | `/m/api/git/files` | HEAD 已跟踪文件列表（v1.1.0 新增） |
| GET | `/m/api/git/file-history` | 单文件提交历史（v1.1.0 新增） |

#### 6.19.1 GET /m/api/git/capabilities

```json
{
  "ok": true,
  "git": {
    "contractVersion": "1.1.0",
    "available": true,
    "reason": null,
    "readOnly": true,
    "provider": "bundled",
    "features": {
      "repository": true, "branches": true, "graph": true, "commit": true,
      "worktree": true, "preview": true, "refsDetail": true, "fileHistory": true
    }
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `contractVersion` | string | 宿主 Git 契约版本；本次为 `1.1.0`（`1.0.0` 为旧版） |
| `available` / `reason` | bool / string\|null | 当前会话是否可用；`reason` 取值 `git-provider-unavailable` / `workspace-registry-unavailable` / `not-git-repository` / `repository-not-authorized` |
| `readOnly` | bool | 恒为 `true` |
| `provider` | string | `bundled`（包内只读实现）或 `external`（外部 provider） |
| `features` | object | 能力位；App 必须按位判断，不得按版本号推断 |

v1.1.0 新增两个**相互独立**的能力位：

- `refsDetail`：graph/commit 返回结构化 `refsDetail` / `tagsDetail`。宿主总是可以给出名称级结构（旧 provider 的原始 refs 字符串会被解析兜底），因此新宿主恒为 `true`。
- `fileHistory`：`/git/files` 与 `/git/file-history` 可用。**只看当前生效的 provider**：external provider 必须自己实现 `files()` / `fileHistory()`；bundled provider 还要求其 Git subprocess 与工作区注册表可用。外部 provider 缺少新方法时该位为 `false`，宿主**不会**用 bundled 数据补齐 external 的 graph/commit 视图（两个端点返回 `503 provider-incompatible`）。

#### 6.19.2 结构化引用：`refsDetail` / `tagsDetail`（graph 与 commit 共用）

graph 的每个提交与 commit 详情都**保留旧的** `refs: string[]`（deprecated，仍为原始 decoration 字符串），并**新增**以下两个数组：

```json
"refsDetail": [
  { "kind": "head", "name": "HEAD", "shortName": "HEAD", "oid": "<commit>", "current": true },
  { "kind": "localBranch", "name": "refs/heads/main", "shortName": "main", "oid": "<commit>", "current": true },
  { "kind": "remoteBranch", "name": "refs/remotes/origin/main", "shortName": "origin/main", "oid": "<commit>" }
],
"tagsDetail": [
  { "name": "refs/tags/nested", "shortName": "nested", "oid": "<commit>", "annotated": true, "hint": "nested-tag" },
  { "name": "refs/tags/nightly", "shortName": "nightly", "oid": "<commit>", "annotated": false },
  { "name": "refs/tags/v1.0.0", "shortName": "v1.0.0", "oid": "<commit>", "annotated": true,
    "tagger": "Alice", "date": 1700000000, "subject": "Release v1.0.0" }
]
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `refsDetail[].kind` | string | `head` / `localBranch` / `remoteBranch` / `other`（tag 不进 refsDetail） |
| `refsDetail[].name` / `shortName` | string | 完整 ref 名 / 规范化短名（去掉 `refs/heads/`、`refs/remotes/`；`HEAD` 保持 `HEAD`） |
| `refsDetail[].oid` | string | 该引用解析到的提交 OID（与所在提交一致） |
| `refsDetail[].current` | bool? | HEAD 与当前本地分支为 `true`；其余省略 |
| `tagsDetail[].name` / `shortName` | string | 完整 tag ref 名 / 短名 |
| `tagsDetail[].oid` | string | tag 解引用后指向的提交 OID（不是 tag 对象 OID） |
| `tagsDetail[].annotated` | bool | 是否为 annotated tag（旧 provider 兜底无法判断时为 `false`） |
| `tagsDetail[].tagger` / `date` / `subject` | string? / number? / string? | 仅 commit 详情的 annotated tag 提供；`date` 为 Unix 秒；`subject` 截断到 200 字 |
| `tagsDetail[].hint` | string? | 只有 commit 详情可能出现 `nested-tag`（tag→tag→commit；graph 行不返回 `hint`）；`non-commit-target` 只属于 provider 契约的 `refs()` 记录（见 §6.19.11），因为目标不是 commit 的 tag 不会出现在任何提交行上 |

约定：

- **顺序**：`refsDetail` 固定 HEAD → 本地分支 → 远程分支 → 其它；`tagsDetail` 按 tag 全名排序。按 `(kind, shortName)`（tag 为 `shortName`）去重。
- 排除 `refs/stash` 与 `refs/remotes/*/HEAD` 等符号引用。
- **graph 行只保证名称级信息**：`tagsDetail` 条目只含 `name` / `shortName` / `oid` / `annotated`；完整 tag 元数据只在 `commit` 详情返回。
- **目标不是 commit 的 tag 不会出现在 graph/commit 的 `tagsDetail`**：它们不指向任何提交行，无法挂在某个提交上；provider 契约仍通过 `refs()` 暴露这些 tag（`hint: "non-commit-target"`）。`nested-tag` 因为最终解引用到提交而出现在对应提交的 `tagsDetail`；graph 行按名称级规则省略该 `hint`。
- **失败降级**：annotated tag 元数据读不到时静默降级为「名字 + `annotated`」，不影响列表展示，不产生错误。

#### 6.19.3 GET /m/api/git/repository、GET /m/api/git/branches

`repository` 响应：`{ ok, repositoryId, name, headOid?, currentBranch?, detached, empty }`。`headOid` 在空仓库省略；`currentBranch` 为 `refs/heads/*` 全名。

`branches` 响应：`{ ok, repositoryId, branches: [{ name, displayName, oid, kind, current, tracking, ahead, behind }] }`，`kind` 为 `local` / `remote`，`name` 为完整 ref 名。

#### 6.19.4 GET /m/api/git/graph

| 参数 | 说明 |
|---|---|
| `tips` | JSON 数组字符串：`[{"name":"refs/heads/main"\|"HEAD"\|"refs/remotes/origin/main","tipOid":"<可选>"}]`，1–5 个且不重复 |
| `snapshotId` / `cursor` | 翻页时成对提交：首次请求省略，响应返回 `snapshotId` 与 `nextCursor` |
| `limit` | 每页条数，1–200，默认 100 |

响应：`{ ok, repositoryId, snapshotId, tips, commits, nextCursor }`，`commits[]` 含 `oid` / `parents` / `author` / `timestamp` / `subject` / `refs` / `refsDetail` / `tagsDetail`。引用在翻页期间移动、tip 失效、快照过期或游标非法返回 `409 graph-stale`；非法 tip 返回 `409 graph-tip-invalid`，超过 5 个返回 `400 graph-too-many-tips`。

#### 6.19.5 GET /m/api/git/commit

| 参数 | 说明 |
|---|---|
| `oid` | 提交 OID（必填，40/64 位十六进制） |
| `filesCursor` / `filesLimit` | 变更文件翻页游标 / 每页条数（1–200，默认 100） |

响应：`{ ok, repositoryId, oid, parents, author, timestamp, message, refs, tags, refsDetail, tagsDetail, stats: { additions, deletions, files }, files: { items, total, nextCursor } }`。`files.items[]` 含 `path` / `oldPath?` / `status`（`added` / `modified` / `deleted` / `renamed` / `copied` / `type-changed`）/ `binary` / `additions` / `deletions`。`tagsDetail` 在此返回完整 annotated tag 元数据（见 §6.19.2）。

#### 6.19.6 GET /m/api/git/worktree、GET /m/api/git/preview

- `worktree`：`{ ok, repositoryId, snapshotId, staged, unstaged, untracked, truncated }`。三类条目含 `path` / `oldPath?` / `status` / `conflicted`；快照最多 2000 条，超出 `truncated: true`。
- `preview`：`kind=staged|unstaged|untracked` 需同时带 `worktree` 返回的 `snapshotId`；`kind=commit` 需带 `oid`。响应 `{ ok, repositoryId, kind, path, oldPath?, diff, truncated, binary, additions, deletions, notice? }`；单文件差异上限 512 KiB，二进制/符号链接/子模块/纯模式变化以 `notice` 说明。

#### 6.19.7 GET /m/api/git/files（v1.1.0 新增）

读取 **HEAD 已跟踪**文件（不是工作区目录列表，未跟踪文件不会出现）。

| 参数 | 说明 |
|---|---|
| `q` | 可选；大小写不敏感的路径子串过滤（服务端过滤） |
| `limit` | 1–200，默认 200 |

```json
{ "ok": true, "repositoryId": "repo_…", "files": ["README.md", "docs/guide.md"], "truncated": false }
```

- `files` 按路径升序；`truncated` 表示还有更多匹配文件未返回（`limit` 截断）。
- 空仓库返回 `{ files: [], truncated: false }`（HTTP 200）。
- **规模上限**：实现读取一次 `git ls-tree -r --name-only HEAD`，受宿主 subprocess stdout 上限 **8 MiB** 约束；仓库路径总表超过该上限时返回 `413 git-output-too-large`（fail-closed，不返回可能错位/截断的半份列表）。`q` 过滤在宿主拿到完整路径表之后执行，不能降低该上限。

#### 6.19.8 GET /m/api/git/file-history（v1.1.0 新增）

单文件提交历史（仅当前 HEAD 可达范围；不做 `--follow` 重命名跟随）。

| 参数 | 说明 |
|---|---|
| `path` | 必填；仓库相对路径或工作区绝对路径（宿主归一化，见下） |
| `cursor` | 可选；不透明分页游标（绑定会话/仓库/路径，过期或非法返回 `400 invalid-history-cursor`） |
| `limit` | 1–100，默认 20 |

```json
{
  "ok": true,
  "repositoryId": "repo_…",
  "path": "docs/guide.md",
  "entries": [
    { "oid": "…", "shortOid": "…", "author": "Alice", "timestamp": 1700000000, "subject": "update guide", "status": "M" }
  ],
  "nextCursor": "…",
  "truncated": false
}
```

- `entries` 按提交从新到旧；`status` 是该提交对 `path` 的变更类型（Git 单字母）。本机 bundled provider 使用 `git log --name-status -M`（**不带 `--follow`**）：重命名在旧路径记录为 `D`、在新路径记录为 `A`，因此 bundled 实际只会产生 `A` / `M` / `D`（以及类型变化的 `T`），不会产生 `R` / `C`；`R` / `C` 只在外部 provider 主动上报时出现。App 按单字母徽标渲染，不得假设 `R` 必然出现。
- 空/异常结果**恒为 HTTP 200**，用 `reason` 表达（不让客户端猜 404）：

| `reason` | 场景 |
|---|---|
| `not-tracked` | HEAD 中不存在该路径（未跟踪/从未提交） |
| `no-history` | 仓库尚无提交（空仓库） |
| `path-invalid` | 越界（`..`、仓库外绝对路径、无法映射的 Windows 绝对路径）或无法归一化的路径 |

- **路径归一化由宿主负责**：接受工作区绝对路径或仓库相对路径，归一化到仓库根内；越界/仓库外返回 `path-invalid`。目录路径（含仓库根、`.`）返回 `400 path-invalid`；只接受文件路径。
- `reason: "path-invalid"` 的 200 响应中，`path` 为客户端提交的原值（便于回填/纠错）；这是客户端输入的回显，不是宿主发现的新路径信息。
- **有界**：单次最多扫描 5000 条提交或 20 秒软超时；达到上限时返回已取部分并 `truncated: true`（客户端可提示「仅显示最近 N 条提交」）。
- 缺失 `path` → `400 bad-request`。

#### 6.19.9 Git 只读端点错误码

| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `bad-request` | 缺 `sessionId` / `repositoryId` / `path`，`tips` 不是 JSON |
| 400 | `invalid-oid` / `invalid-files-cursor` / `invalid-history-cursor` | 非法 OID / 文件分页游标 / 历史分页游标 |
| 400 | `path-invalid` | `/git/file-history` 传入目录路径 |
| 400 | `preview-invalid` | 预览参数非法 |
| 400 | `graph-tip-invalid` / `graph-too-many-tips` | 非法 tip / 超过 5 个 tip |
| 401 | `auth-required` / `bad-token` | 未鉴权（同 §1） |
| 403 | `repository-not-authorized` / `workspace-not-allowed` | 会话/仓库不匹配或路径不在已注册工作区 |
| 404 | `session-not-found` / `not-git-repository` / `preview-file-not-found` | 会话不存在 / cwd 不是仓库 / 提交中无该文件 |
| 409 | `graph-stale` / `graph-tip-invalid` | 快照或 tip 已变化 |
| 413 | `git-output-too-large` | Git 输出超过宿主上限（graph/commit/preview 的输出、`/git/files` 的 HEAD 路径总表，均为 8 MiB 级） |
| 503 | `git-provider-unavailable` / `provider-incompatible` | provider 不可用 / 旧 provider 不支持所需方法 |

#### 6.19.10 兼容与降级

- 契约只做加法：旧 App 忽略新字段即可；旧宿主（无 `refsDetail` / `fileHistory` 能力位）由 App 走字符串解析兜底（`HEAD ->`、`refs/heads/`、`refs/remotes/`、`tag: refs/tags/`）。
- 外部 provider 兼容 `1.0.0`：缺 `refs()` 时宿主用原始 refs 字符串合成名称级 `refsDetail` / `tagsDetail`（`annotated` 按 `false`）；`/git/files`、`/git/file-history` 只在**当前生效的** provider 实现新方法时生效（bundled provider 还要求 subprocess 可用），否则能力位 `fileHistory=false` 且两个端点 `503 provider-incompatible`，**不会**用 bundled 数据补齐 external provider 的视图。
- **成本说明**：graph/commit 读取会额外执行一次 refs 查询（bundled provider 为一次 `for-each-ref`，成本与引用数线性相关；graph 分页每页一次），用于 annotated 元数据与 tag 排序；旧 provider 无 `refs()` 时退回解析 `%D` decoration 字符串。
- `contractVersion` 只随破坏性变更提升主/次版本；`1.x` 内的加法不要求客户端按版本号分支。

#### 6.19.11 外部 provider 契约 v1.1.0（可选加法）

宿主通过内核服务 `gitReadProvider` 读取仓库事实；provider 满足 1.0.0 基础方法即可继续被使用，1.1.0 方法全部**可选**。宿主按**当前生效 provider 的方法存在性**决定能力位，不做跨 provider 混用。

基础契约（`contractVersion` 为 `1.0.0` 或 `1.1.0`）：`capabilities()`、`repositoryRoot(cwd)`、`repositoryInfo(root)`、`branches(root)`、`resolveTip(root, ref)`、`graph(root, { refs, offset, limit })`、`commit(root, oid)`。

1.1.0 可选方法（缺失时宿主按能力位降级）：

| 方法 | 签名 | 返回 | 说明 |
|---|---|---|---|
| `refs` | `refs(root)` | `RefRecord[]` | 全量 ref 记录（见下）。缺失时宿主从 graph/commit 的 `refs` decoration 字符串兜底（annotated 未知，按 `false`） |
| `files` | `files(root, { q, limit })` | `{ files: string[], truncated: boolean }` | HEAD 已跟踪路径；已按 `q`（大小写不敏感子串）过滤并按路径排序；最多 `limit` 条，`truncated` 表示还有更多匹配 |
| `fileHistory` | `fileHistory(root, path, { maxCommits, timeoutMs })` | `{ entries: HistoryEntry[], truncated: boolean, reason?: string }` | `path` 为仓库相对 POSIX 路径；`entries` 从新到旧；`maxCommits` 默认 5000；`timeoutMs` 为软超时（默认 20000ms），超时返回已取部分且 `truncated: true`；`reason` 仅允许 `not-tracked` / `no-history` / `path-invalid` |

`RefRecord`（`refs()` 元素）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `name` | string | `HEAD` / `refs/heads/*` / `refs/remotes/*` / `refs/tags/*` |
| `shortName` | string | 规范化短名（不带 `refs/heads/`、`refs/remotes/`、`refs/tags/`） |
| `kind` | string | `head` / `localBranch` / `remoteBranch` / `tag` |
| `oid` | string | 引用直接指向的对象 OID；annotated tag 为 tag 对象 OID |
| `commitOid` | string \| null | 解引用后提交 OID；轻量 tag 等于 `oid`；目标不是 commit 时为 `null` |
| `current` | bool | 是否 HEAD / 当前分支 |
| `annotated` | bool | tag 是否为 annotated（非 tag 恒 `false`） |
| `tagger` / `date` / `subject` | string? / number? / string? | annotated tag 元数据；`date` 为 Unix 秒；`tagger` 只含姓名（不得含邮箱）；`subject` 原样（宿主按需截断 200 字） |
| `hint` | string? | `nested-tag`（tag→tag→commit）或 `non-commit-target`（最终目标不是 commit） |

`HistoryEntry`（`fileHistory()` 元素）：`{ oid, shortOid, author, timestamp, subject, status }`；`status` 为 Git 单字母（`A`/`M`/`D`/`R`/`C`/`T`，实际出现哪些由 provider 决定）；`author` 只含姓名；`timestamp` 为 Unix 秒。provider 只返回有界结果，不应抛出宿主未知的错误码（未知错误会被映射为 `git-provider-unavailable`）。

约束：provider 不得返回主机绝对路径、remote URL 或邮箱；路径事实必须限定在 `repositoryRoot` 授权仓库内。

### 6.20 轮末产出物与 turnTails（issue #53）

> 只读投影：插件读取会话日志里的 `deliverables/presented`（交付文件声明）与 `workspace/changes`（本轮改动的坐标事件），不写持久状态、不改轮次边界、不新增事件类型。两类来源都**不下发主机绝对路径**：路径只用于服务端解析与派生展示值。本节起的 §6.20–§6.24 全部是**加法扩展**：旧 App 忽略新字段即可，旧插件不下发对应能力位时客户端按各节说明降级。

本轮同时新增三个只读端点：`GET /m/api/changes/summary`（§6.21）、`GET /m/api/changes/diff`（§6.22）、`GET|HEAD /m/api/turn-file`（§6.23）；三者的坐标都来自本节的事件投影。

**能力位 `capabilities.turnTail`**

`GET /m/api/bootstrap`（§3.1）与 SSE `hello` 帧（§3.6）的 `capabilities.turnTail` **同判据、同形状**：

```json
"turnTail": { "version": 1, "presented": true, "changed": true, "changesDiff": true }
```

| 字段 | 类型 | 判定与含义 |
|---|---|---|
| `version` | number | 契约版本，当前恒为 `1` |
| `presented` | bool | 恒为 `true`：交付文件声明来自会话日志，本插件总能投影 |
| `changed` | bool | 宿主**真的注册**了 `workspaceChanges` 服务，且 `summary` 是函数 |
| `changesDiff` | bool | 在上者基础上 `diff` 也是函数（`summary` 与 `diff` 同时可用） |

- **不按宿主版本推断**（ADR 0017）：服务缺失或方法不是函数时 `changed=false`、`changesDiff=false`，形状仍完整下发；探测过程不抛错。
- 旧插件完全不下发该能力位，App 视为全部不可用并隐藏两张轮末卡。
- SSE `hello` 的 `capabilities` 对象同时包含 `eventTimeline` / `turnOutline` / `fileRange` / `turnTail` / `toolCards` / `hold`；§3.6 的示例只截取了前两项。

缺服务时的声明：

```json
"turnTail": { "version": 1, "presented": true, "changed": false, "changesDiff": false }
```

**交付声明 `deliverables/presented` 的移动投影**

事件本身仍进入 `/history` 与 SSE 时间线（事件保真），但**不提供详情**：原始声明含主机路径，`/event-detail` 对它返回 `404 event-not-found`（fail-closed，见 §3.5）。

摘要 envelope 与其它时间线事件一致（`seq` / `type` / 可选 `time` / `data`），`data` 只保留轮号、调用 id 与文件展示字段：

```json
{
  "seq": 3,
  "time": 1750000000123,
  "type": "deliverables/presented",
  "data": {
    "turn": 2,
    "callId": "call_present_1",
    "files": [
      { "id": "4f1c2a9b7d3e5081", "name": "a.ts", "display": "src/a.ts", "description": "最终交付" },
      { "id": "b83d0e6f1a2c4d79", "name": "inside.txt", "display": "rel/inside.txt" }
    ]
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `data.turn` | number? | 轮号；宿主声明缺失/非正整数时省略 |
| `data.callId` | string? | 呈报该批文件的工具调用 id；缺失/空串时省略 |
| `data.files` | array | 最多 **200** 条（按声明顺序截断，不另发截断标记）；`path` 为空/非字符串的条目直接丢弃 |
| `data.files[].id` | string | 不泄路径的稳定身份：规范化路径（相对路径按所属会话 cwd 展开）的 SHA-256 前 **16 位十六进制**；`presented` 与 `/changes/summary` 的 `id` 同源，供 App 合并同一逻辑文件（路径无法归一化时为空串） |
| `data.files[].name` | string | 记录路径的 basename（不是宿主提供的展示名） |
| `data.files[].display` | string | 按下方规则派生的展示路径；**永不包含可拼接的主机绝对路径** |
| `data.files[].description` | string? | 仅当非空时下发；≤200 字符（超出带「已截断」后缀） |

`display` 派生规则（`mobileDisplayPath`，分隔符统一为 POSIX `/`）：

- 记录路径为**相对路径**：原样下发（最多剥掉一次前导 `./`）。
- 记录路径为**绝对路径**：
  - 位于会话工作目录内 → 换算为 cwd 相对路径（记录 `/proj/src/a.ts`、cwd `/proj` → `src/a.ts`）；
  - 恰为 cwd 本身 → 取 basename；
  - 位于用户家目录下 → `~/…`（如 `~/.config/x`）；
  - 其余 → 只给 **basename**。
- cwd 未知（休眠会话/旧宿主）：相对路径仍原样，绝对路径退化为 basename（家目录规则仍先判定）。
- 空路径 → 空串。

同一轮多次 `present` 时，App 按 `id` 去重（缺 `id` 的旧记录退回 `(seq, index)` 坐标作身份，保守保留多条）、`description` 取该轮**最后一次**声明（按持久坐标 `seq` 优先、同 `seq` 比 `index` 判定，历史与实时同判据）；`id` 不可逆且不含主机前缀，只能用于合并，不能反推路径。

**`/history` 增量 `turnTails`**

`GET /m/api/history` 的 200 响应新增 `turnTails`（与 `events` 同级）。它由**一次遍历完整原始事件**得出（会话日志仍含被时间线过滤的 `workspace/changes`），**不受 `after`/`before`/`limit` 分页影响**；只包含**有产出物**的轮次，key 为轮号的字符串形式，按轮号升序：

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "after": 5121,
  "hasMore": false,
  "turnTails": {
    "2": { "changes": true, "presented": true },
    "3": { "changes": true, "presented": false }
  },
  "events": []
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `turnTails` | object | 恒存在；无任何产出物时为 `{}` |
| `turnTails[turn].changes` | bool | 该轮存在 `workspace/changes` |
| `turnTails[turn].presented` | bool | 该轮存在 `deliverables/presented` 且 `files` 非空 |

- `workspace/changes` **不进入移动时间线**（`/history`、SSE 实时流、`/event-detail` 三处同规则：已知且不具呈现价值的记录），改动信号只经 `turnTails` / `tail` 下发。
- `turn/end` 的 **SSE 摘要**额外携带 `data.tail`（同形；无产出物时字段整体缺省，不写 `null`）。该字段**只出现在实时摘要**，`/history` 的 `turn/end` 摘要不带它——历史侧用 `turnTails`：

```json
{ "seq": 4, "type": "turn/end", "time": 1750000000000, "data": { "turn": 2, "reason": { "kind": "completed" }, "tail": { "changes": true, "presented": true } } }
```

**客户端消费约定**：`presented=true` 渲染交付卡、`changes=true` 渲染改动卡（`changesDiff` 决定能否打开单文件对比，见 §6.22）；两项都缺省时不渲染任何轮末卡。历史与实时两条路径必须得到同一结论：实时用 `turn/end.data.tail` 立即收口，重连/回放用 `turnTails` 补齐。

> 验证：`test/turn-tail-routes.test.mjs`（投影、能力位、`turnTails`、SSE `tail`）、`tools/timeline-contract-check.mjs`（§6.20 契约自检）。

### 6.21 GET /m/api/changes/summary（本轮改动文件摘要）

**鉴权**：沿用全局 token 闸门（§1）：`X-Mobile-Token` 或 Cookie 二者任一通过；未通过 → `401 auth-required`。Host 不在白名单 → `403 host-not-allowed`；口令失败超限 → `429 rate-limited`（仅启用口令时，见 §4）。

**查询参数**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `sessionId` | string | 是 | 目标会话 |
| `turn` | number | 是 | 轮号，非负整数（宿主轮号从 1 开始；`turn=0` 合法但不会命中任何轮次，通常得到 `absent`） |

非 GET/HEAD → `405 method-not-allowed`（HEAD 与其它 GET 端点一致：路由放行、无响应体）。参数错误走 `400 bad-request`，不返回部分结果。

**响应 200（`available`）**

```json
{
  "ok": true,
  "state": "available",
  "turn": 2,
  "files": [
    {
      "seq": 2,
      "index": 0,
      "id": "4f1c2a9b7d3e5081",
      "display": "src/a.ts",
      "name": "a.ts",
      "added": 12,
      "deleted": 3,
      "binary": false,
      "oversized": false
    }
  ],
  "total": 2,
  "added": 12,
  "deleted": 3,
  "truncated": false
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `state` | string | `available` / `absent` / `unavailable`（三态见下） |
| `turn` | number | 回显请求的轮号 |
| `files` | array | 改动文件列表，最多 **200** 条（`TURN_TAIL_MAX_FILES`） |
| `files[].seq` | number | 该轮**最新**一条 `workspace/changes` 事件的 durable seq；`/changes/diff` 与 `/turn-file?kind=changed` 的 `seq` 坐标来源 |
| `files[].index` | number | 宿主摘要 `files[]` 的下标（截断前；与 `/changes/diff`、`/turn-file` 的 `index` 同一坐标） |
| `files[].id` | string | 与 `deliverables/presented` 同源的路径摘要（规范化路径的 SHA-256 前 16 位十六进制），不泄路径；无法归一化时为空串 |
| `files[].display` | string | 按 §6.20 规则重新派生的展示路径（**不信任**宿主给的绝对 display） |
| `files[].name` | string | 记录路径的 basename（记录路径缺失时退回展示值） |
| `files[].added` / `deleted` | number | 宿主统计的非负整数；缺失/非法回退 `0` |
| `files[].binary` | bool | 宿主标记的二进制文件；缺省 `false` |
| `files[].oversized` | bool | 宿主标记的超大文件；缺省 `false` |
| `total` | number | **全量**改动文件计数（宿主 `total`，缺失时回退宿主 `files.length`），不受 200 截断影响 |
| `added` / `deleted` | number | 本轮全量增删行数；缺失/非法回退 `0` |
| `truncated` | bool | 是否还有未下发的文件 |

**三态（均为 HTTP 200 正常响应，不是错误）**

| `state` | 触发条件 | 响应形状 |
|---|---|---|
| `available` | live 会话；该轮存在 `workspace/changes`；宿主 `summary()` 返回合法对象（`files` 为数组） | 正常文件列表；`files` 可为空数组（合法的空摘要） |
| `absent` | live 会话，但该轮**没有** `workspace/changes` 事件（如只读轮/未产生改动） | `files: []`、`total: 0`、`added: 0`、`deleted: 0`、`truncated: false` |
| `unavailable` | `workspaceChanges` 服务缺失或无 `summary`；会话非 live（休眠/宿主重启后未激活）；`summary()` 抛错或返回非法形状 | 同 `absent` 的空形状 |

- 休眠会话与「改动服务缺失」都归入 `unavailable`，**不返回 5xx**——客户端统一降级，不占位、不报错。
- `sessions` 里查不到该会话（不存在/休眠/已归档）同样归入 `unavailable`：本端点**不返回** `404 session-not-found`，因为「读不到改动」与「会话不存在」对轮末卡是同一种降级结果。
- `absent` 与 `unavailable` 必须区分：前者是「这一轮确实没有改动」，后者是「现在读不到改动」。`available` 配空 `files` 也是合法的空列表（宿主明确给出「没有改动文件」）。
- **截断**：`truncated=true` 的条件是「宿主 `files.length > 200`」或「宿主 `total > files.length`」（宿主自己还有更多未返回）；`total` 始终是全量计数，绝不因 200 截断而改小。
- 响应**不含** `cwd`、`path`；文件只以 `id` / `display` / `name` / 统计字段出现。

**HTTP 错误码**

| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `bad-request` | 缺 `sessionId`；缺 `turn`；`turn` 非非负整数 |
| 401 | `auth-required` / `bad-token` | 未提供凭证 / 口令错误（§1） |
| 403 | `host-not-allowed` | Host 不在白名单（docs/04） |
| 405 | `method-not-allowed` | 非 GET/HEAD |
| 429 | `rate-limited` | 口令失败超限（仅启用口令时；响应带 `Retry-After`，§4） |
| 503 | `sessions-unavailable` | 宿主 `sessions` 服务不可用（此时无法判断会话是否 live） |

> 注意：本端点不会返回 `503 changes-unavailable`——`workspaceChanges` 缺失是 200 的 `unavailable` 态（与 §6.22、§6.23 的 `changed` 分支不同）。

> 验证：`test/turn-tail-routes.test.mjs`（available/absent/unavailable、200 上限与 `total`、绝对路径重派生、400/503）。

### 6.22 GET /m/api/changes/diff（本轮单文件统一 diff）

**鉴权**：同 §6.21（全局 token 闸门）。非 GET/HEAD → `405 method-not-allowed`。

**查询参数**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `sessionId` | string | 是 | 目标会话（必须处于 live 状态） |
| `turn` | number | 是 | 轮号，非负整数 |
| `index` | number | 是 | 文件下标，非负整数；与 §6.21 的 `files[].index` 同一坐标 |

**响应 200（可对比文本）**

```json
{
  "ok": true,
  "state": "available",
  "diff": {
    "kind": "text",
    "display": "src/a.ts",
    "before": true,
    "after": true,
    "coarse": false,
    "diff": "--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,1 +1,2 @@\n-const a = 0;\n+const a = 1;\n+const b = 2;\n",
    "truncated": false
  }
}
```

不可对比（二进制 / 超大）：

```json
{ "ok": true, "state": "available", "diff": { "kind": "binary", "display": "bin.dat" } }
```

`ok` 恒为 `true`，`state` 恒为 `available`；本端点**没有** 200 的降级态，读不到就是 4xx/5xx。

| 字段 | 类型 | 说明 |
|---|---|---|
| `diff.kind` | string | `text` / `binary` / `oversized` |
| `diff.display` | string | 展示路径，按 §6.20 规则从宿主 `diff.path`（缺失时退回 `diff.display`）+ 会话 cwd 重新派生；仍取不到则 basename。绝不直通宿主绝对路径 |
| `diff.before` | bool | 仅 `text`：对比前文件是否存在（`false` 表示新增） |
| `diff.after` | bool | 仅 `text`：对比后文件是否存在（`false` 表示删除） |
| `diff.coarse` | bool | 仅 `text`：布尔值，宿主标记的近似对比（宿主未标记时为 `false`） |
| `diff.diff` | string | 仅 `text`：统一 diff 文本（见下） |
| `diff.truncated` | bool | 仅 `text`：是否按体积上限截断 |

文本渲染规则（供客户端 `GitFileViewer` 差异模式直接消费）：

- 文件头：`--- a/<display>` 与 `+++ b/<display>`；`before:false` → `--- /dev/null`，`after:false` → `+++ /dev/null`。
- 每个 hunk 一行头：`@@ -<oldStart>,<oldLines> +<newStart>,<newLines> @@`（宿主缺省/非法值按 `0` 渲染）。
- hunk 内的行原样输出，保留前导 `+` / `-` / 空格；整段文本以换行结尾。
- **512 KiB 体积上限**（`TURN_TAIL_DIFF_MAX_BYTES = 512 * 1024`）：按**行边界**截断——只保留放得下的完整行，置 `truncated:true`（绝不切断一行造成解析错位）；极端情况（首行本身即超限）`diff` 为空串且 `truncated:true`。
- `binary` / `oversized` 分支只给 `kind` 与 `display`，**不带** `diff` 文本；客户端按 `kind` 显示不可对比提示。
- 200 响应不含 `path` / `cwd`；文件名只以 `display` 出现。

**HTTP 错误码**

| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `bad-request` | 缺 `sessionId`；缺 `turn` 或 `index`；`turn`/`index` 非非负整数 |
| 401 | `auth-required` / `bad-token` | 未提供凭证 / 口令错误（§1） |
| 403 | `host-not-allowed` | Host 不在白名单（docs/04） |
| 404 | `diff-not-found` | 会话非 live（休眠/重启后未激活）；该轮没有 `workspace/changes`；宿主 `diff(sessionId, seq, index)` 返回空（index 越界、摘要失效） |
| 405 | `method-not-allowed` | 非 GET/HEAD |
| 429 | `rate-limited` | 口令失败超限（仅启用口令时，§4） |
| 503 | `changes-unavailable` | `sessions` 服务缺失；`workspaceChanges.diff` 缺失；`diff()` 读取抛错 |

> 与 §6.21 的差异：休眠会话在摘要端点是 200 `unavailable`，在本端点是 `404 diff-not-found`——没有 live 会话就没有可对比的基准；客户端按各自语义降级即可。

> 验证：`test/turn-tail-routes.test.mjs`（统一 diff 文本、512 KiB 截断、binary、404/400/503、绝对路径重派生）。

### 6.23 GET|HEAD /m/api/turn-file（按轮末记录坐标读取文件）

**鉴权**：同 §6.21（全局 token 闸门）。

**客户端只提交坐标，不提交路径**（GitLab #16 收紧方向）：文件路径由服务端从会话记录/改动摘要中解析；客户端若额外传 `path` 参数会被忽略。

**查询参数**

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `sessionId` | string | 是 | 目标会话 |
| `kind` | string | 是 | `presented`（交付文件声明）或 `changed`（本轮改动文件）；其它值 → `400` |
| `seq` | number | 是 | `presented`：`deliverables/presented` 事件的 durable seq；`changed`：该轮 `workspace/changes` 事件的 seq（即 §6.21 `files[].seq`） |
| `index` | number | 是 | `presented`：`data.files[index]`；`changed`：宿主摘要 `files[index]` |

`seq` / `index` 必须是非负整数。坐标解析规则：

- `kind=presented`：先经 `sessionQuery.readEvent({ sessionId, seq })` 读取（休眠会话可用），回退 live 会话快照，再回退 `readSession` 的完整事件；事件必须是 `deliverables/presented`，`files[index].path` 必须是非空字符串。相对记录路径按读取到的会话 cwd 展开；cwd 未知且路径为相对 → 无法解析。**不使用** `workspaceChanges`。
- `kind=changed`：要求 live 会话且 `workspaceChanges.summary` 可用；调用 `summary(sessionId, seq)` 取 `files[index].path`，相对路径按摘要 `cwd` 展开。休眠会话、服务缺失、摘要失败/形状非法 → `503 changes-unavailable`。
- 两种坐标都**不接受客户端指定的路径**；文件不存在/不可读只在服务端解析后进行，错误体不回显主机路径。

**响应：文件字节流**

| 状态 | 场景 | 关键响应头 |
|---|---|---|
| `200` | 完整文件（或 HEAD 探测） | `content-length`、`etag`、`last-modified`、`accept-ranges: bytes` |
| `206` | 单区间命中 | 追加 `content-range: bytes <start>-<end>/<size>` |
| `304` | `If-None-Match` 命中（支持 `*` 与逗号列表） | 带 `etag` 与 `cache-control`，无响应体 |
| `416` | Range 非法/越界 | `content-range: bytes */<size>`、`content-length: 0` |

响应头约定：

- `content-type`：按扩展名映射（`txt`/`md`/`json`/`pdf`/`png`/`jpg`/`jpeg`/`gif`/`webp`/`zip`/`gz`/`doc`/`docx`/`xls`/`xlsx`/`csv`/`yaml`/`yml`/`js`/`ts`/`py`/`html`/`mp4`/`apk` 等）；其余一律 `application/octet-stream`。
- `content-disposition: attachment; filename*=UTF-8''<编码后的文件名>`。
- `etag` 为强标记，含文件大小、mtime 与 ctime（避免同大小改写且恢复 mtime 后沿用旧断点）；`cache-control: no-store`。
- 一律 `connection: close`（一问一答，取完即断，避免半关连接复用）。

Range / 条件请求语义：

- **只支持单区间**：`bytes=start-end`、`bytes=start-`、`bytes=-suffix`；多区间、格式非法、`start >= size`、`end < start` 都返回 `416`（带 `Content-Range: bytes */<size>`）。
- `If-Range` 只有**当前强 ETag 完全一致**时才返回区间；旧标记、弱标记、日期标记一律退回完整 `200`（客户端应截断旧文件后从头写）。
- `HEAD` 与 GET 返回同一组头（`content-length`、`etag`、`last-modified`，带 Range 时含 `content-range`），但无响应体。
- `If-None-Match` 在 Range 判断之前生效：命中即 `304`，无响应体。

**HTTP 错误码**

| HTTP | error 值 | 场景 |
|---|---|---|
| 400 | `bad-request` | 缺 `sessionId`；`kind` 不是 `presented`/`changed`；`seq`/`index` 缺失或非非负整数 |
| 401 | `auth-required` / `bad-token` | 未提供凭证 / 口令错误（§1） |
| 403 | `host-not-allowed` | Host 不在白名单（docs/04） |
| 404 | `record-not-found` | `presented` 事件不存在/类型不符、`files[index]` 无有效 `path`、相对路径无 cwd 可解析；或 `changed` 的 `summary.files[index]` 无 `path`、相对路径无摘要 cwd 可解析 |
| 404 | `file-not-found` | 记录存在，但目标文件已删除/不可读/不是普通文件（错误体不含主机路径） |
| 404 | `not-found` | 非 GET/HEAD：该路径只注册 GET/HEAD，其它方法落到未知子路径 |
| 429 | `rate-limited` | 口令失败超限（仅启用口令时，§4） |
| 503 | `sessions-unavailable` | 宿主 `sessions` 服务不可用 |
| 503 | `changes-unavailable` | `kind=changed` 且：`workspaceChanges.summary` 缺失、会话非 live、摘要读取失败或形状非法 |

> `presented` 与 `changed` 的依赖不同：前者只需要会话记录/`sessionQuery`（休眠会话也能读），后者必须依赖 live 会话的 `workspaceChanges` 摘要。客户端应按 `kind` 分别处理 503 与 404。

> 验证：`test/turn-tail-routes.test.mjs`（presented 字节与 Range/HEAD/ETag/304、工作区外与相对路径、休眠会话、changed 坐标、`record-not-found`/`file-not-found`/400/503、错误体脱敏）。

### 6.24 工具卡结构化投影（issue #54 / #66 / #67 / #68）

> `tool/call` / `tool/result` 的既有摘要字段不变，新增**结构化 `summary`**：只从原始参数、结果文本与宿主 `meta` 的稳定形状派生，字段走安全白名单；路径一律派生为展示值。解析失败、未知工具、畸形参数都不抛错——没有 `summary` 时 App 回退现有通用卡（fail-open）。

**能力位 `capabilities.toolCards`**

`GET /m/api/bootstrap` 与 SSE `hello` 帧**同判据、同形状**：

```json
"toolCards": {
  "version": 1,
  "tools": ["bash", "pwsh", "read", "write", "edit", "grep", "glob", "web_fetch", "web_search", "read_image", "todo_write", "ask_user_question", "skill"],
  "ptc": { "version": 1 }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `version` | number | 工具卡投影版本，当前恒为 `1`（只增不改） |
| `tools` | string[] | 本插件实际投影的 **13** 个工具，顺序固定；只增不删 |
| `ptc.version` | number | PTC 子调用树版本，当前恒为 `1`（见 §6.24.1） |

- 声明按**本插件实现**给出，不按宿主版本推断；未列入 `tools` 的工具（未知/自定义）一律回退通用卡。
- `tools` 固定清单（13 个）：`bash`、`pwsh`、`read`、`write`、`edit`、`grep`、`glob`、`web_fetch`、`web_search`、`read_image`、`todo_write`、`ask_user_question`、`skill`。
- 键序固定 `version` → `tools` → `ptc`：加法扩展不破坏既有消费方的文本断言。
- 旧插件完全不下发该能力位，App 全部回退通用卡。

**`tool/call` 的 `data.summary`**

按工具名映射到固定 `kind`；除 `kind` / `tool` 外，其余字段均可选（取不到就缺省，绝不发 `null`）：

| `kind` | 工具 | 字段 |
|---|---|---|
| `command` | `bash` / `pwsh` | `command`（换行压成空格，≤200）、`workdir`（展示路径，≤300）、`background`（仅 `run_in_background === true` 时发 `true`）、`description`（单行化，≤120） |
| `file` | `read` / `write` / `edit` | `filePath`（展示路径，≤300）；`read` 另有 `offset` / `limit`（仅正整数，非法忽略）；`write` 另有 `sizeKb`、`diff?`、`diffTruncated?`；`edit` 另有 `sizeKb`、`added`、`deleted`、`diff?`、`diffTruncated?` |
| `search` | `grep` / `glob` | `pattern`（单行化，≤200）、`path`（展示路径，≤300）；`grep` 另有 `include`（单行化，≤200） |
| `web` | `web_fetch` | `url`（trim，≤500） |
| `web` | `web_search` | `query`（`queries[]` 中第一个非空字符串，单行化，≤200） |
| `image` | `read_image` | `filePath`（展示路径，≤300） |
| `todo` | `todo_write` | `items[]`（≤50，元素 `{ content ≤200, status }`，`status` ∈ `pending` / `in_progress` / `completed`，未知状态归一为 `pending`）、`counts`（`{ pending, inProgress, completed }`，三数之和 = `items.length`） |
| `question` | `ask_user_question` | `questions[]`（≤10，元素 `{ question ≤300, id? ≤120, header? ≤80, options? ≤20 [{ label ≤120, description? ≤200 }], multiSelect? }`）；缺 `question` 的题整题丢弃，无 `label` 的选项逐项丢弃 |
| `skill` | `skill` | `name`（≤120） |

补充口径：

- **未知工具**：不产生 `summary`（`tool/call.data` 仍保留 `name` 与 `arguments`）。
- **参数解析**：`data.arguments` 可以是 JSON 字符串或对象；非法 JSON/非对象 → 只给 `{ kind, tool }` 的最小摘要（App 仍能渲染通用卡）。`todo_write` 的 `todos`、`ask_user_question` 的 `questions` 不是数组时同样只给最小摘要（不猜结构）。
- **`sizeKb`**：`write` = `ceil(content 的 UTF-16 长度 / 1024)`；`edit` = `ceil((old_string.length + new_string.length) / 1024)`（与桌面 `NKB` 同口径）。
- **`added` / `deleted`**：`edit` 按行数近似（`old_string` 全列为删除、`new_string` 全列为新增；忽略末尾换行产生的空行），仅用于折叠行统计。
- **内联 diff**：`write` 给全新增统一 diff（`--- /dev/null`、`+++ b/<display>`、`@@ -0,0 +1,N @@`）；`edit` 给近似统一 diff（`old_string` 全列为 `-`、`new_string` 全列为 `+`）。整段体积 ≤ **8 KiB**（`TOOL_CARD_DIFF_MAX_BYTES`）时下发 `diff`；超出则**整段缺省**并置 `diffTruncated: true`（不截半段，避免 App 的 diff 解析错位）。`filePath` 缺失时 `edit` 不给 `diff`，但仍给 `added` / `deleted`。
- **路径**：`filePath` / `workdir` / `path` 均由 `mobileDisplayPath` 派生（规则同 §6.20），摘要内绝不出现主机绝对路径。
- **预览字段**：`read` / `write` / `edit` / `read_image` 可能额外带 `relative` / `previewable`，见 §6.24.2。

示例（`write`）：

```json
{
  "seq": 51,
  "type": "tool/call",
  "data": {
    "turn": 1,
    "step": 1,
    "callId": "call-1",
    "name": "write",
    "arguments": "{\"file_path\":\"src/new.ts\",\"content\":\"第一行\\nsecond line\\n\"}",
    "summary": {
      "kind": "file",
      "tool": "write",
      "filePath": "src/new.ts",
      "sizeKb": 1,
      "diff": "--- /dev/null\n+++ b/src/new.ts\n@@ -0,0 +1,2 @@\n+第一行\n+second line\n"
    }
  }
}
```

**`tool/result` 的 `data.summary`**

| 字段 | 触发工具 | 来源与规则 |
|---|---|---|
| `exitCode` | 仅确定是 `bash` / `pwsh` | 结果**末尾**的 `[exit code: N]`（N 可为负）；只认最后一条且其后仅剩空白，stdout 正文里的同形文本不算 |
| `signal` | 仅 `bash` / `pwsh` | 末尾的 `[killed by signal: X]`（≤40） |
| `stopped` | 仅 `bash` / `pwsh` | 末尾的 `[stopped: …]`（≤120） |
| `resultCount` | `grep` / `glob`；结果事件无工具名，或 `meta.shape` 为 `matches`/`paths` 时也认 | 优先宿主 `meta.total`；否则按稳定文本句式解析（`Found x of y matches`、`No matches found`、`(Showing x of y paths`、`No files found`，以及 glob 的纯路径行数）；解析不到则缺省 |
| `answers` | 仅 `ask_user_question` | 结果文本为 JSON `{ answers: [{ id, selected, custom? }] }` → `[{ questionId, values[] }]`；`custom` 追加在 `values` 末尾，`selected` 为空时保留空数组；`pending` 形状/坏 JSON/无有效 `id` → 缺省 |

- `exitCode` / `signal` / `stopped` 互斥：取结果末尾**最后一条**终止标记（signal/stopped/exit 由宿主追加，正文里的假标记不得覆盖真实状态）；工具名未知时不从内容猜，必须由 `/history` 或 SSE 按 `callId → tool/call.name` 关联后再判定。
- `resultCount` 只对搜索类工具、结果事件无工具名、或宿主明确给出 `meta.shape` 的结果生效；已知的非搜索工具（如 `read`）文本里出现的 `Found 3 matches` 不会被误判。
- 解析不到任何字段时不写 `summary`（不写空对象）。

示例（`bash`）：

```json
{
  "seq": 52,
  "type": "tool/result",
  "data": {
    "turn": 1,
    "step": 1,
    "callId": "call-1",
    "name": "bash",
    "isError": false,
    "text": "boom\n[exit code: 7]",
    "summary": { "exitCode": 7 }
  }
}
```

**与既有字段的关系**

- `tool/call.data` 的既有 `arguments`（≤2000 字符，截断带「已截断」后缀）与 `name` 不变，`summary` 是纯增量。
- `tool/result.data` 的既有 `text`（≤2000 字符）、`isError`、`images`（≤20）不变，`summary` 是纯增量；终止状态从**未 clamp 的原始文本**解析，长输出末尾的 trailer 不会被 2000 字上限截掉。
- `summary` 自身没有版本号字段，版本由 `capabilities.toolCards.version` 承担。

> 验证：`test/tool-cards-projection.test.mjs`（13 工具字段、8 KiB diff 降级、结果解析）、`tools/timeline-contract-check.mjs`（工具卡投影契约自检）。

#### 6.24.1 PTC 子调用投影（issue #68）

> PTC（`run_code` 内被调度的工具）的子调用以两条会话事件表达：`tool/ptc-dispatch-start`（执行前）与 `tool/ptc-dispatch`（落定）。服务端把二者投影为同一形状的摘要，App 以 `callId` 合并 start→result，并挂到根工具卡下。

**事件仍属 debug-only**：两条事件都在 `/history` 与 SSE 实时流下发（可回放、可调试），但**不在** `/event-detail` 的 allow-list（`DETAIL_VISIBLE_TYPES`）——摘要不带 `detail` 指针，直接请求详情返回 `404 event-not-found`；普通模式不单独渲染，调试模式可展开裸事件（§3.5、§3.6 的既有口径）。

**start 摘要 `data`**

```json
{
  "seq": 19,
  "type": "tool/ptc-dispatch-start",
  "data": {
    "turn": 3,
    "step": 2,
    "rootCallId": "call_root",
    "parentCallId": "call_root",
    "callId": "call_root:ptc:1",
    "name": "read",
    "status": "running",
    "summary": { "kind": "file", "tool": "read", "filePath": "README.md", "limit": 3 }
  }
}
```

**result 摘要 `data`**（在 start 字段基础上追加/改写）

```json
{
  "seq": 20,
  "type": "tool/ptc-dispatch",
  "data": {
    "turn": 3,
    "step": 2,
    "rootCallId": "call_root",
    "parentCallId": "call_root",
    "callId": "call_root:ptc:1",
    "name": "read",
    "status": "success",
    "isError": false,
    "summary": { "kind": "file", "tool": "read", "filePath": "README.md", "limit": 3 }
  }
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `turn` / `step` | number? | 由**原始会话事件**（含被 timeline 过滤的 `step/start`）扫描到该 `seq` 为止派生；派生不到就省略，**禁止用 0 伪造**；App 不依赖它排序 |
| `rootCallId` | string? | 根工具调用 id；缺失/非法（非字符串、空串、>300）时省略 |
| `parentCallId` | string | 发起子调用的父 id；**必填**，非法/缺失 → 整条 `data` 缺省 |
| `callId` | string | 内核 `subCallId`（形如 `<parentCallId>:ptc:<n>`）；wire 字段名是 `callId`，**不是** `subCallId`；非法/缺失 → 整条 `data` 缺省 |
| `name` | string? | 工具名，≤120；空串/非字符串时省略 |
| `status` | string | start 恒为 `running`；result 为 `success`（`isError !== true`）或 `failed`（`isError === true`） |
| `isError` | bool | 仅 result 下发；start 不带 |
| `text` | string? | **仅失败 result**：只含安全错误码（`error.code` 优先，缺失时 `error.name`），≤500；语法受限（见下），绝不使用 `content` / `arguments` / `meta` / `error.reason` |
| `error` | object? | **仅失败 result**：只含 `{ name, code }`，各 ≤120；`name` 与 `code` 必须**都**通过安全码语法才下发 |
| `summary` | object? | 折叠行安全摘要（见下），start 与 result 都可能带 |
| `truncated` | true? | 仅「超预算通知」条目（见 50 子调用预算）；此时不带 `turn` / `step` / `summary` / `text` / `isError` / `error`，但保留 `rootCallId` / `parentCallId` / `callId` / `name` / `status` |

**安全码语法**：`^[A-Za-z][A-Za-z0-9_.-]{0,63}$`，**不做 trim**——含空格、换行、制表符、路径字符（如 `/`）的原串一律非法。非法时 `text` 退回另一个合法字段（code 非法则用 name），`error` 需要 name 与 code 同时合法，否则省略。

**`summary` 白名单**：复用 `tool/call` 的派生结果，但按 App 折叠行白名单裁剪，并限制整份 JSON ≤ **2 KiB**（`PTC_MAX_SUMMARY_BYTES`）；超预算整份降级为 `{ kind, tool }`，绝不抛错。

| `kind` | 保留字段 |
|---|---|
| `command` | `command`、`workdir`、`background`、`description` |
| `file` | `filePath`、`offset`、`limit`、`sizeKb`、`added`、`deleted` |
| `search` | `pattern`、`path`、`include` |
| `web` | `url`、`query` |
| `image` | `filePath` |
| `todo` | `items`、`counts` |
| `question` | `questions` |
| `skill` | `name` |

- 明确**丢弃**仅为二级详情设计的 `diff` / `diffTruncated` / `relative` / `previewable`：PTC 折叠行不承载大块 diff 与跳转坐标。
- `command` / `description` 是自由文本，PTC 侧额外做主机路径脱敏：先保护 `http(s)://` URL，再把 cwd/cwd realpath/家目录前缀替换为 `.` / `~`，其余绝对路径（含引号内、Windows、`file:///`、`--flag=/…` 形态）折叠为 `…/<basename>`。
- `filePath` / `workdir` / `path` 等结构字段已由 `mobileDisplayPath` 派生，不重复处理。
- 永不下发 `arguments` 原文、`meta`、`content`、`images`、`error.reason`。

**50 子调用预算**

- 计数作用域：`/history` **每个响应**新建一个预算；SSE **每会话**一个（进程内 Map，最多 200 个会话、FIFO 逐出；不持久化，重启清零）。
- 计数粒度：按 `rootCallId` 分组（缺失归入空串根），组内按 `callId` 去重；同一 `callId` 的 start/result **共享 1 个名额**，重复事件不占新名额。
- 前 50 个唯一 `callId` 全量投影；第 51 个唯一 `callId` 只发**一条**最小截断通知（不带 `turn` / `step` / `summary` / `text` / `isError` / `error`，每个计数作用域只发一次）：

```json
{
  "seq": 99,
  "type": "tool/ptc-dispatch-start",
  "data": {
    "rootCallId": "call_root",
    "parentCallId": "call_root",
    "callId": "call_root:ptc:51",
    "name": "read",
    "status": "running",
    "truncated": true
  }
}
```

- 通知之后再出现的新 `callId`（含第 51 个 `callId` 的 result）一律降级为 `{ seq, type }`（有合法顶层 `time` 时仍保留 `time`），不带 `data`。
- 已计数的前 50 个 `callId` 的迟到 result 仍**全量**投影；不同 `rootCallId` 的预算互相独立。
- 纯函数调用（未传预算）永不截断，仅测试/内部使用。

**客户端消费约定（子调用树）**

- App 按 `parentCallId` 接边，`callId` 去重；start/result 任意顺序到达都不降级：result 先行时保持 settled，start 只补缺失的 `name`/`summary`；重复 result 原地 last-write-wins。
- 父未知 → 节点保持 orphan（不渲染、不伪造根），父到达后逐层挂回；自环/祖先环/重复父静默忽略。
- **深度上限 16 是客户端渲染规则，服务端不做深度截断**：App 把子树物化为 DFS 先序扁平列表（根下第 1 层 `depth=1`），最多渲染 16 层；第 17 层起对应根的 `subCallsTruncated=true`。App 侧每根另有 50 条二次上限（与服务端预算独立）。恰好 16 层的叶子不误报截断。

> 验证：`test/ptc-subcalls-projection.test.mjs`（真实夹具投影、安全白名单、50 预算/notice/drop、turn/step 派生、debug-only）、`test/fixtures/ptc/`（DSH 0.2.2-rc.1 真实捕获）、`tools/timeline-contract-check.mjs`（PTC 契约自检）；深度 16 的客户端规则见 `dsh-mobile-app/lib/timeline.dart` 与 `dsh-mobile-app/test/ptc_subcalls_test.dart`。

#### 6.24.2 路径可点预览字段（relative / previewable，issue #67）

> 只对 `read`、`write`、`edit`、`read_image` 四个文件类工具生效；其它工具即便参数里带了 `file_path` 也不产生这两个字段（不因参数形状扩大能力）。语义是 **fail-closed**：不确定可预览时两字段一起缺省，绝不下发 `previewable: false`。

**同现约束**：两字段**要么同时出现，要么同时缺省**。出现时形状恒为：

```json
{ "kind": "file", "tool": "read", "filePath": "src/a.ts", "relative": "src/a.ts", "previewable": true }
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `relative` | string | cwd 相对 POSIX 路径：无前导 `/`、无盘符、无 `\`、无空段/`.`/`..`/含 `:` 段；**≤300 字符**（`TOOL_CARD_PREVIEW_PATH_MAX`），超出**整段缺省、绝不截断**——截断后的路径会指向另一个文件 |
| `previewable` | `true` | 出现时恒为 `true`；不下发 `false`，也不下发 `null` |

**fail-closed 清单**

| 情形 | 结果 |
|---|---|
| cwd 缺失/空/非绝对路径/不存在/不是目录 | 两字段缺省 |
| 原始路径非字符串、空串、含 NUL、首尾有空白、原始长度 >4096 | 两字段缺省 |
| POSIX 形态 cwd 下原始路径含 `\` | 缺省（`\` 在 POSIX 是合法文件名字符，归一成 `/` 可能指向另一份文件；仅 Windows 形态 cwd 才做 `\`→`/` 归一） |
| 绝对路径在 cwd 之外（含 `C:\…`、UNC、`/etc/passwd`） | 缺省，且**不对该路径做任何 fs 探测**（判定不得变成敏感目录存在性探测器） |
| 空段 / `.` / `..` / 含 `:` 的段（`/`、`//x`、`a//b`、`src/./b.ts`、`a/../b`） | 缺省；只剥一次前导 `./` |
| 目标是目录 / FIFO / socket / 设备 | 缺省（`/turn-file` 只对普通文件开放） |
| 目标不可读（权限不足） | 缺省 |
| 符号链接逃逸 cwd | 缺省；目标仍在 cwd 内则允许，`relative` 保留用户路径的词法形状（如 `alias/inner.txt`） |
| 文件不存在（如 `write` 执行前的新文件） | 缺省（存在性口径：摘要生成时目标必须已存在） |
| `relative` 长度 >300 | 两字段缺省（不截断） |

**探测边界**：

- preview 判定本身**零 fs 探测 cwd 外的绝对路径**：先完成全部词法校验，只有词法已在 cwd 内的候选才做 cwd realpath、目标 realpath containment（拒绝符号链接逃逸）与 `isFile` / `R_OK` 验证。
- 同一条摘要的 `display` / `filePath` 派生（`mobileDisplayPath`）在合并 cwd 符号链接别名时可能对已给出的绝对路径祖先做 realpath；那是 §6.20 / 工具卡的既有 display 语义，不属于 preview 判定。
- `filePath` 的 300 字 clamp 与 `relative` 的 300 字上限是两件事：前者是既有 display 口径（可截断），后者超限**整段缺省**。

> 验证：`test/issue67-file-path-preview.test.mjs`（cwd 内外、词法拒绝、符号链接、不可读/FIFO、300 字边界、四工具覆盖、同现约束）、`test/tool-cards-projection.test.mjs`（旧字段只增不改）。
