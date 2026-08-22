# 03 API 接口设计文档 — dsh-mobile-remote

> 版本：v2.8.2 · 状态：已实现 · 配套：00-开发总纲.md、02-architecture.md、04-security.md、09-compatibility.md
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
| GET | `/m/api/history` | 指定会话的事件历史（增量） | 是 |
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
  "agents": [
    { "id": "session-abc", "status": "running", "hasPending": false }
  ],
  "sessions": [
    { "id": "session-abc", "createdAt": 1750000000000, "cwd": "F:\\DSH-Outpost" }
  ]
}
```

- `urls`：按优先级排列——首个非 internal IPv4（含 Tailscale 100.x 段）在前，loopback 最后；`port` 来自 `ctx.webServer.port`。v3.0.0：`lanBridge` 监听成功时首选地址为桥地址（`http://<IP>:<lanBridge.port>`，端口默认 3080），回环 webserver 地址仅作本机自连兜底。
- `agents[].status`：`"running" | "idle"`（映射自 agent 状态与最近事件推断）。
- 未认证：`401`（见通用约定）。
### 3.2 POST /m/api/send
**请求**

```json
{ "sessionId": "session-abc", "text": "帮我跑一下测试", "mode": "steer" }
```

- `sessionId` 可选：指定会话（必须存在且其 agent 存活）；缺省 → 第一个 root agent。
- `mode` 可选（v2.7.2）：`"followup"`（默认，排队到下一轮）| `"steer"`（插队：消息插到 agent 下一步执行，适合 team 插件子会话向主会话插队）。agent 空闲时 `steer` 自动降级为 `followup`，响应 `note: "agent-idle-followup"`。
**响应**

- `200 { "ok": true, "agentId": "session-abc", "messageId": "m_<uuid>", "mode": "followup" | "steer" }`
- `400 { "error": "empty-text" }`：text 为空或非字符串
- `404 { "error": "session-not-found" }`：指定会话不存在
- `503 { "error": "no-live-agent" }`：无匹配的运行中 agent
- `503 { "error": "agents-unavailable" }`：agents 服务不可用（非 web 组合或启动中）
**语义**：服务端构造 `createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })` 后调用 `agent.followup(message)`（排队）或 `agent.steer(message)`（插队）。`followup` 会持久化消息并唤醒空闲驱动器；不等待执行结果（结果经 SSE 回流）。
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

- 排序：`lastActivity` 倒序（无活跃记录时回退 `createdAt`）。数据源：优先 `sessionQuery.listSessions()`（含休眠会话），回退 `ctx.sessions.list()`（仅活动会话）。
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
**过滤规则**：只返回会话"表面"事件（`user/message`、`assistant/message`、`tool/call`、`tool/result`、`turn/start`、`turn/end`）。token 级 `assistant/chunk`、`agent/inbox/spliced`、`request/*` 等日志型事件不返回（数量可达十万级，会淹没移动端；完整回复由 `assistant/message` 兜底）。SSE 实时流不受此过滤影响。
**响应 200**

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "after": 42,
  "events": [
    { "seq": 43, "type": "user/message", "data": { "text": "帮我跑一下测试" } }
  ]
}
```

`events[]` 使用与 SSE 帧相同的摘要格式（见 3.6），保证客户端去重逻辑单一。数据源：`ctx.sessions.get(id).events`（追加式冻结快照，天然按 seq 有序）。
- `404 { "error": "session-not-found" }`

### 3.6 GET /m/api/events（SSE）
`Content-Type: text/event-stream`。帧格式（`data:` 单行 JSON）：

```json
{ "type": "session/event", "sessionId": "session-abc", "seq": 44, "event": { "type": "turn/end", "data": { "reason": { "kind": "complete" } } } }
```

**事件摘要 `event` 字段**（服务端裁剪，见 02 §5.2）：

| event.type | event.data 内容 |
|---|---|
| `user/message` | `{ text: string }`（text blocks 拼接，≤2000 字符） |
| `assistant/message` | `{ text: string, reasoningChars: number }` |
| `assistant/chunk` | `{ text: string }`（仅文本 delta） |
| `tool/result` | `{ name: string, isError: boolean, text: string }`（≤2000 字符） |
| `turn/start` | `{ turn: number }` |
| `turn/end` | `{ turn: number, reason: object }` |
| 其他 | 仅 `type`，无 data（客户端忽略） |

**控制帧**：连接建立后立即 `data: {"type":"hello","serverTime":...}`；每 25s `: ping` 注释行。
**错误语义**：鉴权失败在连接建立阶段以 `401` HTTP 状态返回（EventSource 会触发 error 事件，客户端转登录态）。

### 3.6b SSE 帧类型汇总（v2.3+ 扩展）

除 3.6 的 `session/event` 外，SSE 还会推送：

| type | 说明 |
|---|---|
| `session/context` | `{ sessionId, contextWindow }`——模型上下文窗口（`request/context` 事件，PC 端圆环同源） |
| `agent/status` | `{ agentId, sessionId, status, child }`——running / waiting / idle；`sessionId` 为去 `session:` 前缀的会话 id，`child` 标记子代理会话（v2.7.2 起携带后两字段） |
| `notifications/changed` | 通知记录增删（如移动端删除后），客户端刷新列表与角标 |
| `mobile/notify` | `{ notification: { id, kind, sessionId, title, detail, time } }`——插件"真结束"判定后推送的通知（completed / failed / needs-answer），悬浮球/App 与通知中心同源渲染（v2.7.2） |
| `mobile/frame` | 内核瞬态帧（问询/审批/队列）。`frame` 字段为 `question/requested`（含 `rpcId`、`questions[]`）、`question/resolved`（`questionRpcId`）、`approval/requested`（`rpcId`、`approvalId`、`toolName`、`reason?`）、`approval/resolved`（`approvalId`）、`session/queue`。**App 断线重连时服务端补发挂起的待答帧**（`pendingFrames` 回放） |

客户端应按 `type` 分派；未知 type 一律忽略（前向兼容）。
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
| GET | `/m/api/directories` | 目录浏览（盘符/子目录，v2.1） |
| POST | `/m/api/directories` | 新建文件夹（v2.1） |
| GET | `/m/api/diagnostics` | 环境诊断（服务端端点实测，v2.1） |
| GET | `/m/api/balance` | DeepSeek 官方余额（服务端代查，v2.1） |
| GET | `/m/api/qr-config` | 桌面二维码数据（loopback only，v2.1） |
| POST | `/m/api/defaults` | 修改默认 Agent/权限预设（v2.1） |

### 6.2 GET /m/api/catalog

返回 PC 端真实枚举（单一事实源，客户端不硬编码）：
```json
{
  "ok": true,
  "models": [
    { "id": "deepseek-v4-flash", "name": "DeepSeek-V4-Flash" },
    { "id": "deepseek-v4-pro", "name": "DeepSeek-V4-Pro" }
  ],
  "reasoningEfforts": ["off", "high", "max"],
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
    "model": "deepseek-v4-flash",
    "reasoningEffort": "max",
    "permissionPreset": "workspace-write",
    "agentPreset": "standard"
  }
}
```

数据来源：`ctx.llm.listProviders()/listModels()`、provider 配置（reasoningEffort 枚举）、`ctx.sandboxPolicy`/permission-presets 服务、agent-presets 目录 manifest（name/description）。默认值来自 settings/配置树。
### 6.3 GET /m/api/session-config

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "config": {
    "model": "deepseek-v4-flash",
    "reasoningEffort": "max",
    "permissionPreset": "workspace-write"
  }
}
```

### 6.4 POST /m/api/session-config

**请求**（三个字段均可选，只更新给定项）：

```json
{
  "sessionId": "session-abc",
  "model": "deepseek-v4-pro",
  "reasoningEffort": "high",
  "permissionPreset": "danger-full-access",
  "confirmDanger": true
}
```

- `permissionPreset` 为 `danger-full-access` 时 `confirmDanger` 必须为 `true`，否则 `400 { "error": "risk-confirmation-required" }`（与 PC 端 Full access 需显式确认风险一致）。
- 权限写入走 PC 端同一路径（`permission/preset` + sandbox/approval 旋钮事件）。
- 修改当前会话配置不产生新事件；`404 session-not-found`。
### 6.5 POST /m/api/sessions（新建会话）

**请求**：
```json
{
  "preset": "standard",
  "model": "deepseek-v4-flash",
  "reasoningEffort": "max",
  "permissionPreset": "workspace-write"
}
```

- `preset` 必填（客户端从 catalog 选择；默认值由服务端 `defaults.agentPreset` 兜底）；其余可选。
- 服务端：`ctx.agents.create({ preset, ... })`（按 preset 组合会话），随后按参数覆写配置。
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
{ "ok": true, "parentAvailable": true, "subagents": [
  { "id": "…", "kind": "child", "status": "running", "title": "…" }
]}
```
- 映射内核 `subagent.list`（payload `{ parentSessionId }`）；`status` = activity（running/inactive）或 diagnostic reason
- 缺参数 `400 parentSessionId-required`；会话不存在 `404 session-not-found`

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
    "input": { "hint": "[<objective>|clear|edit <objective>|pause|resume]", "images": true } }
] }
```
- 命令条目：`name` / `description` 必填；`input`（`hint` / `images`）可选，有则返回
- `commands` 服务未注册（无 dsh-commands host 服务）→ `200 { ok, commands: [], unavailable: true }`（App 端弹「无可用命令」，不硬 503）
- 会话不存在 → `404 session-not-found`；缺 `sessionId` → `400 bad-request`

**POST `/m/api/commands`** — 执行斜杠命令
```json
请求: { "sessionId": "…", "line": "/goal" }
响应: { "ok": true, "result": { "commandId": "cmd-…", "result": { "kind": "success", "text": "…" } } }
```
- 映射内核 `commands.execute(agent, line, images, signal)`（0.1.1-rc.2 四参签名；本插件 `images` 恒为空数组，`signal` 为 15s 超时中止；2.8.1 的旧三参调用会把 AbortSignal 误传 images 槽，已改正）
- `line` 必须以 `/` 开头（否则 `400 bad-request`）；未知/畸形命令 `404 command-not-found`；服务未注册 `503 commands-unavailable`（带 detail）；服务在而会话不存在 `404 session-not-found`（与 GET 拆分语义一致）
- `result` 为内核 settle 对象（`commandId` + `result.{kind,text}`），与 PC 端一致





