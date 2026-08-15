# 05 测试用例设计文档 — dsh-mobile-remote

> 版本：v2.4.0 · 状态：已按实际验证结果填写（含 v2.3 问询/审批、通知删除端到端用例） · 配套：03-api.md、04-security.md
> 环境：Windows + dsh web（web profile） + Android（DSH Remote App）
> 前置：插件已安装并启用；访问口令为安装时生成的随机串（下文 `<TOKEN>`）。
## 1. 测试范围与环境
- 功能：认证、发消息、事件回流、历史、会话、通知、新建会话、目录、默认配置、二维码。
- 安全：口令校验、Host 校验、loopback 限制。
- 兼容：Android 深色/浅色主题。
- 自动化：`tools/e2e-check.mjs`（Node ≥ 20，`DSH_MOBILE_TOKEN` 环境变量）覆盖核心 API 链路。
## 2. 功能测试用例

### F-01 认证：未携带凭证访问 API

| 项目 | 内容 |
|---|---|
| 步骤 | 不带凭证请求 `GET /m/api/bootstrap` |
| 预期 | 401 `{"error":"auth-required"}` |

### F-02 认证：错误口令
| 项目 | 内容 |
|---|---|
| 步骤 | 携带错误 token 请求 `GET /m/api/bootstrap` |
| 预期 | 401 `{"error":"auth-required"}` |

### F-03 认证：正确口令
| 项目 | 内容 |
|---|---|
| 步骤 | 携带正确 token（`X-Mobile-Token` 头）请求 `GET /m/api/bootstrap` |
| 预期 | 200 `{"ok":true}` |

### F-04 bootstrap 状态
| 项目 | 内容 |
|---|---|
| 步骤 | 带 token 请求 `/m/api/bootstrap` |
| 预期 | 200；`auth.enabled=true`；`server.urls` 含局域网 IPv4 与 127.0.0.1；`agents` 含运行中会话；`sessions` 非空 |

### F-05 发消息（端到端，自动化覆盖）

| 项目 | 内容 |
|---|---|
| 步骤 | 连 SSE（带 token）→ `POST /m/api/send {sessionId, text}` |
| 预期 | send 200 `{ok, agentId, messageId}`；SSE 收到 `session/event` 帧（user/message → assistant/message） |
| 实测 | ✅ 端到端通过（App 发送 → 会话收到 → 回复回流） |

### F-06 发消息：空文本
| 项目 | 内容 |
|---|---|
| 步骤 | `POST /m/api/send {text:""}` |
| 预期 | 400 `{"error":"empty-text"}` |

### F-07 发消息：无运行中 agent

| 项目 | 内容 |
|---|---|
| 前置 | 电脑端无任何会话 |
| 步骤 | `POST /m/api/send`（不带 sessionId） |
| 预期 | 503 `{"error":"no-live-agent"}` |

### F-08 历史加载

| 项目 | 内容 |
|---|---|
| 步骤 | `GET /m/api/history?sessionId=<id>&after=0&limit=200` |
| 预期 | 200；事件按 seq 升序，摘要格式与 SSE 一致 |

### F-09 新建会话

| 项目 | 内容 |
|---|---|
| 步骤 | `POST /m/api/sessions {preset, cwd}` |
| 预期 | 200 `{sessionId}`；PC 端会话列表出现；cwd 在工作区子目录时自动归属该工作区 |

### F-10 通知与已读
| 项目 | 内容 |
|---|---|
| 步骤 | 任务完成 → `GET /m/api/notifications` → `POST /m/api/notifications/read` |
| 预期 | 通知出现且同会话同类型聚合为一条；标记已读后 unread 归零 |

### F-11 默认配置修改

| 项目 | 内容 |
|---|---|
| 步骤 | `POST /m/api/defaults {agentPreset:"code"}` |
| 预期 | 200；`GET /m/api/catalog` 的 defaults.agentPreset 变更为 code |

### F-12 二维码端点
| 项目 | 内容 |
|---|---|
| 步骤 | `GET /m/qr.png?text=<url>` |
| 预期 | 返回 `image/png` |

### F-13 桌面二维码数据（qr-config）
| 项目 | 内容 |
|---|---|
| 步骤 | loopback 请求 `GET /m/api/qr-config` |
| 预期 | 200 `{urls, token, path}`；非 loopback → 403 |

### F-14 目录浏览

| 项目 | 内容 |
|---|---|
| 步骤 | `GET /m/api/directories?path=` → 盘符；`path=F:\` → 子目录；`POST /m/api/directories {path,name}` |
| 预期 | 盘符/子目录列表正确；新建文件夹成功 |

### F-15 问询弹窗（端到端，v2.3）

| 项目 | 内容 |
|---|---|
| 前置 | 桌面端已重启（加载弹窗桥）；App 诊断 `respondBridge`/`frameBridge` ✅；PC 与手机同时打开同一会话 |
| 步骤 | 发指令触发 `ask_user_question`（带选项）→ 观察两端弹窗 → 手机选选项提交 |
| 预期 | ① 两端同时弹卡片；② 提交后 agent 收到答案（PC 端可见答案生效）、两端卡片同步消失 |
| 变体 A | 手机输入自定义答案提交（单选语义：选项与自定义二选一） |
| 变体 B | 手机点 ✕ → 卡片即时消失，agent 收到取消（`ASK_CANCELLED`） |
| 变体 C | PC 端先答 → 手机卡片同步消失；手机后答提示"可能电脑端已先回答" |
| 变体 D | 断网期间产生问询 → App 重连后补发弹窗（pendingFrames 回放） |

### F-16 权限审批弹窗（端到端，v2.3）

| 项目 | 内容 |
|---|---|
| 前置 | 会话权限预设 Workspace Write、审批策略「询问」 |
| 步骤 | 指令触发工作区外写文件 → 两端弹「权限请求」→ 手机点「允许一次」 |
| 预期 | ① 两端同时弹；② 允许后操作继续（文件写入成功）、卡片消失 |
| 变体 A | 点「拒绝」→ 操作被拒（agent 收到拒绝结果）、卡片消失 |
| 变体 B | 策略「从不询问」→ 不弹窗（内核直接按预设处理），无报错 |

### F-17 通知删除

| 项目 | 内容 |
|---|---|
| 步骤 | 通知页长按单删 / 垃圾桶批量多选 / 清空全部；随后让 agent 再完成一轮任务 |
| 预期 | ① 删除后列表与角标即时刷新（SSE `notifications/changed`）；② 新事件仍正常产生新通知（删除≠静音）；③ PC 端通知中心不受影响 |

## 3. 安全测试用例

### S-01 Host 校验

| 项目 | 内容 |
|---|---|
| 步骤 | 请求带 `Host: evil.example.com` 访问 `/m/api/bootstrap`（带有效 token） |
| 预期 | 403 `{"error":"host-not-allowed"}` |

### S-02 qr-config loopback 限制

| 项目 | 内容 |
|---|---|
| 步骤 | 非 loopback 来源请求 `GET /m/api/qr-config` |
| 预期 | 403 `{"error":"loopback-only"}` |

### S-03 口令关闭模式

| 项目 | 内容 |
|---|---|
| 前置 | patch 将 `authToken` 置空并重启 |
| 步骤 | 无凭证访问 `/m/api/bootstrap` |
| 预期 | 200（无认证） |

### S-04 监听范围

| 项目 | 内容 |
|---|---|
| 步骤 | `netstat`/`Get-NetTCPConnection` 查看 3080 监听地址 |
| 预期 | `0.0.0.0:3080`（已配置局域网/Tailscale 访问时）；确认公网端口未开放 |

## 4. 回归执行建议

- 每次修改插件源码后：`cd C:\Users\<用户>\.dsh\profiles\web && corepack pnpm install`（同步 file: 副本）→ 重启 dsh web → 跑 `tools/e2e-check.mjs` → 手机 App 冒烟（连接/发消息/通知/新建会话）。
- 修改 App 后：`flutter analyze` → `flutter build apk --release` → 覆盖安装。
