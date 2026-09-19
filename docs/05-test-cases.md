# 05 测试用例设计文档 — dsh-mobile-remote

> 版本：v3.1.1（2026-08-26 发布，v3.0.0 之前内容已按实际验证结果填写；v3.1.0 用例见 F-20~F-22，v3.1.1 用例见 F-23） · 配套：03-api.md、04-security.md
> 环境：Windows + DSH Desktop（desktop profile，内核 0.1.1-rc.2；web profile 亦适用） + Android（DSH Remote App）
> 前置：插件已安装并启用（LAN 桥监听 0.0.0.0:3080）；访问口令为安装时生成的随机串（下文 `<TOKEN>`）。
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

### F-18 登录限流（v2.6，端到端）

| 项目 | 内容 |
|---|---|
| 前置 | `authToken` 已启用 |
| 步骤 | 连续错误口令请求 `/m/api/bootstrap`（错误 token） |
| 预期 | 阈值（10 次/60s）内 401；超限后 `429 { "error": "rate-limited" }` + `Retry-After` 头；窗口过后自动恢复；正确口令成功后计数重置 |
| 变体 A | `authToken` 未启用（留空）时无限流，按原语义返回 |
| 说明 | `tools/e2e-check.mjs` 末尾已含自动化断言（封锁后本机 IP 60s 内 429，故段位置于脚本最后） |

### F-19 链接 scheme 白名单（v2.6，App 单元测试）

| 项目 | 内容 |
|---|---|
| 步骤 | `flutter test test/md_link_test.dart` |
| 预期 | http/https 放行；`file:`/`intent:`/`tel:`/`javascript:`/`data:` 与解析失败/空串一律返回 null（渲染为纯文本不可点击） |

### F-20 思维链字段（reasoning，v3.1.0 候选，端到端）

| 项目 | 内容 |
|---|---|
| 前置 | 插件与 App 均为 v3.1.0 代码（assistant/message 摘要含 `reasoning`；App 渲染折叠块） |
| 步骤 | 连 SSE → 让 agent 回复一条带思考过程的消息（任何任务即可）→ 观察 assistant/message 摘要与 App 渲染 |
| 预期 | ① 摘要 `reasoning` = 全部 reasoning 类型 content 块文本拼接，≤20000 字符（超长截断并附「已截断」）；② 无 reasoning 块时**不发送**该字段；③ 流式与历史摘要均携带；④ App 在消息上方渲染可折叠「思维链」块（图标+字数+箭头），默认状态跟随设置「思维链默认展开」，单条消息独立切换，手动状态按消息持久化 |
| 变体 A | 思维链 >20000 字符：截断显示，无乱码/异常 |
| 变体 B | 旧版 App（≤v3.0.0）接收带 reasoning 摘要：忽略字段，按无折叠块的历史样式显示 |
| 实测 | ✅ 端到端通过（真机：折叠块渲染/切换/持久化；logcat 无异常） |

### F-21 会话标题字段（title，v3.1.0 候选，端到端）

| 项目 | 内容 |
|---|---|
| 步骤 | 带 token 请求 `/m/api/bootstrap` → 检查 agents/sessions 条目；App 回桌面点悬浮球看「运行中的会话」面板 |
| 预期 | ① agents/sessions 条目含 `title`（`sessionTitleOf ?? shortSessionId` 兜底）；② 悬浮球面板显示会话标题（超宽省略号截断），而非 session id 短码；③ 旧版插件（无 title）时 App 回退显示 id 短码 |
| 实测 | ✅ 端到端通过（真机：面板显示会话标题） |

### F-22 思维链折叠状态持久化（v3.1.0 候选，App 真机）

| 项目 | 内容 |
|---|---|
| 步骤 | 设置「思维链默认展开」任意态 → 手动折叠某条消息的思维链块 → ① 列表滚动离开再滚回 ② 退出会话重新进入 ③ 杀进程重启 |
| 预期 | 手动折叠/展开状态保持（按会话+消息 key 持久化在 `dsh_mr_reasoning_overrides`，每会话软上限 100 条）；未手动切换的消息跟随设置默认值 |
| 实测 | ✅ 真机全部通过（滚动/重进/重启） |

### F-23 WSL/类 Unix 路径选择（v3.1.1，issue #5，单测）

| 项目 | 内容 |
|---|---|
| 前置 | 插件 v3.1.1 + App v3.1.1+，服务端运行在 WSL/Linux |
| 步骤 | App 新建会话 → 工作目录 → 根视图 → 进入 `/home` 逐级进入真实目录 → 「选这里」→ 创建会话 |
| 预期 | ① 根视图（POSIX）显示「根目录」、根项 `/`；进入 `home` 后路径为 `/home`（**回归：旧版拼成 `/\home` 并报「读取失败」**）；② 目录可逐级浏览、可新建文件夹；③ 新建会话 cwd 为所选真实路径；④ 「已注册工作区」显示服务端原始路径（非 `\home\user` 归一形态），点选直接可用 |
| 变体 A | Windows 服务端回归：根视图盘符、`C:\` 逐级浏览、新建文件夹、cwd 与 v3.1.0 行为一致 |
| 变体 B | 旧版 App（≤v3.0.0）+ 新版插件：浏览路径为 `/\home` 形态，服务端归一化后仍可正常进入/选择（`//home` 在 POSIX 与 `/home` 等价） |
| 单测 | `flutter test test/dirpicker_logic_test.dart`（joinDirPath/dirSepOf）；`node tools/wsl-path-check.mjs`（normalizeServerPath，8/8） |

### F-24 对话时间线能力与历史/实时一致

| 项目 | 内容 |
|---|---|
| 前置 | 插件返回 `capabilities.eventTimeline`；准备 user、assistant、tool/call、tool/result、unknown Visible event 与长参数/结果 |
| 步骤 | App 连接 SSE → 记录实时事件；断线后请求 `/history`；展开工具卡与未知事件详情 |
| 预期 | 事件顺序和 durable seq 一致；工具按 callId 合并且显示完整生命周期；长详情按需加载；未知事件通用卡可展开；历史分页 `hasMore` 可补齐所有缺口 |
| 变体 A | 旧插件无 capability / 无详情端点 |
| 预期 | 保留旧摘要与聊天；详情显示“不可用”，不伪造数据 |
| 变体 B | 手机离线后展开详情 |
| 预期 | 已缓存摘要保留；详情显示不可用并可在恢复连接后重试 |
| 单测 | `node tools/timeline-contract-check.mjs`（未知/内部事件过滤、详情指针、`/event-detail` 鉴权与身份校验、bootstrap agentId→sessionId，40/40）；`flutter test test/timeline_test.dart`（reducer 合并规则：tool/call 替换 delta 参数、锚点/detail seq 收敛、可见性分类）|

### F-25 普通/调试模式与富内容

| 项目 | 内容 |
|---|---|
| 步骤 | 普通模式查看工具、注入事件、图片/Markdown/文件结果；切换调试模式逐条展开 |
| 预期 | 普通模式摘要且隐藏选定 runtime 注入与协议元数据（`session/title`、`model/selection`、`feedback/*` 等）；调试模式显示协议元数据、未知事件、原始工具 IO；图片/Markdown 可预览，文件可下载到应用私有目录（提示显示完整路径）；系统提示词、请求快照与压缩摘要永不显示 |
| 变体 | 并行同名工具、失败工具、已解决的审批、todo/Job 状态、压缩前事件、流式工具参数（delta → tool/call）|
| 预期 | 各自按 callId/事件 seq 保持独立；工具参数以 `tool/call` 的完整实参为准（不得出现 delta 与整串拼接）；审批走 durable `approval/asked`/`approval/decided` 可历史回放，问询只有瞬态帧（重进会话不保证回放）；失败默认展开 |

> 边界说明：问询（`question/requested`）在核心里只有瞬态远程帧、没有 durable 事件，因此**不保证**历史回放；审批有 durable 事件，重进会话仍可见。

### F-26 断线多页 catch-up 与滚动锚点

| 项目 | 内容 |
|---|---|
| 步骤 | 生成超过 100 条未读 Visible event，断开 SSE，恢复连接并向上翻历史 |
| 预期 | catch-up 持续读取 `hasMore` 直到 durable cursor 收敛；重复帧不重复渲染；加载更早事件不改变当前 viewport 锚点 |

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
| 预期 | `0.0.0.0:3080`（LAN 桥启用，局域网/虚拟组网可访问）；确认公网端口未开放 |

## 4. 回归执行建议

- 每次修改插件源码后：`cd C:\Users\<用户>\.dsh\profiles\desktop && corepack pnpm install`（同步 file: 副本）→ 重启 DSH Desktop → 跑 `tools/e2e-check.mjs` → 手机 App 冒烟（连接/发消息/通知/新建会话/图片发送）。
- 修改 App 后：`flutter analyze` → `flutter test`（`test/api_logic_test.dart`：多地址合并/轮换、回环与链路本地排除，5 用例；`test/md_link_test.dart`：链接 scheme 白名单）→ `flutter build apk --release` → 覆盖安装。
