# 09 兼容性说明（Compatibility）

> 版本：v2.4.0 · 面向：开源使用者 / 二次开发 / 多设备部署

本文回答两个问题：**App 在哪些手机上能跑**，以及**插件在什么样的 Harness 上能跑**。

---

## 1. 版本要求

| 组件 | 要求 |
|---|---|
| 桌面端 DSH（Harness） | 与开发基线同系列（本文档基于 **v0.1.0-rc.6 服务包 + 2026-08 桌面发行版** 编写）；更低版本可能缺少 `apiProxy`/`workspaceRegistry` 等服务，功能会按 §2 降级 |
| dsh-mobile-remote 插件 | v2.4.0（本仓库）；`/m/api/diagnostics` 可自检 |
| 手机 App（Android） | Android 7.0+（`minSdk` 跟随 Flutter 引擎默认）；64 位机型 |
| Flutter 构建环境 | Flutter 3.35+（Dart SDK ^3.13） |

**快速自检**：手机 App → 设置 → 环境诊断。`services` 一节列出每个内核服务是否存在；`checks.respondBridge` / `checks.frameBridge` 为 ✅ 表示问询/审批弹窗桥已就绪；`checks.pendingFrames` 是**计数**（当前挂起的待答弹窗数，0 = 正常无待答，>0 = 有问询/审批等待处理）。

---

## 2. 内核耦合点与降级行为

插件与 Harness 的耦合分三档：**硬依赖**（缺失 = 对应功能不可用）、**软依赖**（缺失 = 功能降级）、**可选**（缺失 = 自动禁用该功能）。插件对每个依赖都做了存在性探测，**任何一项缺失都不会让插件崩溃或影响其他功能**。

### 2.1 服务（`ctx.get` / `ctx.inject`）

| 服务 | 用途 | 档位 | 缺失时行为 |
|---|---|---|---|
| `webServer` | 挂载 `/m/api`、`/m/events`、`/m/qr.png` 路由 | 硬依赖（插件存在的意义） | v2.4 起守卫：纯 headless 形态下插件静默无操作，不崩进程 |
| `sessions` | 会话列表/touch/创建/停止 | 硬依赖（内核核心） | 移动端会话功能不可用 |
| `agents` | 会话创建、状态 | 硬依赖（内核核心） | 同上 |
| `workspaceRegistry` | 工作区列表、会话归档（与 PC 端同一份状态） | 软依赖 | 归档/工作区筛选不可用；App 回退为 cwd 前缀分组（旧版兼容路径） |
| `messageFeedback` | 消息 👍/👎（与 PC 端同一份） | 软依赖 | 反馈菜单隐藏/报错 |
| `approval` | 权限策略读取（`setPolicy` 仅当存在时调用） | 可选 | 跳过策略写入 |
| `credentials` | DeepSeek 余额查询 | 可选 | 回退环境变量 `DEEPSEEK_API_KEY`；都没有则余额不可用 |
| `apiProxy` | 问询/审批弹窗桥 + 应答回写 | 可选（v2.3+ 新功能） | `checks.respondBridge=false`，手机不弹问询/审批卡（PC 端不受影响）；`/m/api/respond` 返回 503 |
| `userQuestions` | （间接）问询链路 | 可选 | 无弹窗（同上） |

> ⚠ **apiProxy 属私有协议**：`events.mux` 与 `respond` 的消息格式是 PC 端 GUI 的内部通道，**无版本稳定承诺**。插件以 `ctx.inject(["apiProxy"])` 获取并做函数存在性探测；若未来 Harness 重构该接口，桥会干净降级（不影响其他功能），随插件版本更新恢复。这是本插件对内核唯一的"越界"耦合，集中在 `lib/index.js` 的「问询/审批帧桥」一段。

### 2.2 事件与 RPC

| 内核接口 | 用途 | 风险与降级 |
|---|---|---|
| `ctx.on("session/event")` | 消息流/通知聚合/上下文窗口 | 事件形态随版本演进；未知类型一律透传不解析，解析异常被 try/catch 兜底 |
| `ctx.on("agent/status")` | 状态点（绿/橙） | 同上 |
| `session.models` RPC | 模型目录（App 模型选择器） | 失败 → 目录为空，App 隐藏模型胶囊 |
| `settings.update`（`agent-presets` / `permission` 命名空间） | 默认预设修改 | 与 PC 端同一写入通道；命名空间变更会导致设置失败（App 报错提示） |
| `session.fork` | 消息分支 | 内核接口变化 → fork 失败提示 |
| `agent.followup` / `session.cancel` | 发消息/停止 | 同上 |

### 2.3 高度自定义化的 Harness

- **自定义权限预设/模型/Agent 预设**：App 全部从内核动态读取（catalog、session-config），不内置白名单；未知预设名显示为「…」（后续版本可拉取预设清单美化）。
- **第三方插件动作**：`ctx.mobileActions.register(...)` 注册后自动出现在 App 动作区（v0.1 契约：仅 text 字段）。
- **自定义问答 provider / 自动审批策略**：若用户的 Harness 已经接管人类问询（如自动答题插件、审批策略改为自动放行），内核**不会产生** `question/requested` / `approval/requested` 帧——手机不弹窗是**正确行为**，不是 bug。
- **多 profile**：插件按 profile 安装（`<profile>/node_modules/dsh-mobile-remote`），每个 profile 独立配置口令/连接。

---

## 3. Android 多品牌适配

App 为 Flutter 原生 APK（`com.dsh.remote`），渲染后端为 **Impeller（Vulkan，自动回退 OpenGLES）**。

| 维度 | 状态 | 说明 |
|---|---|---|
| 渲染 | ✅ 已验证（小米 17 Pro Max） | Flutter 引擎在无 Vulkan 机型自动回退 GLES；再老机型回退 Skia。历史风险点：部分旧 Mali GPU 的 Impeller 花屏（2024 年问题，现版本基本修复） |
| 系统版本 | Android 7.0+ | minSdk 跟随引擎默认 |
| 明文 HTTP | ✅ | `usesCleartextTraffic=true` 已配置（Android 9+） |
| 扫码 | ✅ | mobile_scanner（CameraX）全品牌通用 |
| 后台存活 | 部分依赖系统 | 国产 ROM 杀后台会断 SSE；App 有指数退避重连 + 回前台自动探测。系统级提醒走推送桥（ntfy/Bark/Server酱），不依赖 App 存活 |
| 深色/字体缩放 | ✅ | Flutter 主题自适应 |

**建议发布前实测**（借 1~2 台其他品牌即可）：① 长时间流式回复渲染；② 上翻深历史（Impeller 表现）；③ 熄屏后回前台自动重连。

**如遇渲染异常**：把 `dsh-mobile-app/android/app/src/main/AndroidManifest.xml` 中 `EnableImpeller` 改为 `false` 出一个 Skia 版验证；App 代码无需改动（列表结构两种后端都验证过）。

## 4. iOS（未开发）

- **Dart 代码零平台依赖**，5 个插件（shared_preferences / http / path_provider / mobile_scanner / url_launcher）均有 iOS 实现；iOS 只有 Impeller 后端，而列表结构恰在 Impeller 下验证过。
- 需要：Mac + Xcode + 开发者账号（或 TestFlight）。
- 必须的配置项（预计半天）：`Info.plist` 放行局域网 http（ATS `NSAllowsLocalNetworking`）、iOS 14+ 本地网络权限文案（`NSLocalNetworkUsageDescription`）、相机权限文案。

## 5. 已知问题清单（发布时如实告知）

| # | 问题 | 影响 | 状态/缓解 |
|---|---|---|---|
| 1 | 问询/审批桥依赖 apiProxy 私有协议 | 未来内核大版本可能断桥 | 干净降级 + 插件版本跟进；诊断可查 |
| 2 | 自定义权限预设名在 App 显示「…」 | 纯展示 | 后续拉取预设清单 |
| 3 | 国产 ROM 杀后台导致通知延迟（App 内角标） | 通知不及时 | 推送桥不受影响；App 重连后补拉 |
| 4 | Impeller 在极老 GPU 的潜在渲染问题（未实测） | 少数旧机可能花屏 | manifest 一行回退 Skia |
| 5 | 大体积消息（数万字符）首次滚动定位 | 仅首屏定位，无功能损失 | 列表已按段加载（50 条/页） |
| 6 | 明文 HTTP 通信 | 仅限可信内网 | 设计如此（docs/04-security.md）；公网必须 Tailscale |
| 7 | 通知记录删除后，同会话同类事件会再生成新通知 | 符合预期（删除≠静音） | 已文档化 |

## 6. 发布签名

- Release APK 需正式 keystore：`dsh-mobile-app/android/app/dsh-release.jks` + `android/key.properties`（**均已 gitignore，切勿提交**）。
- 干净克隆无 key.properties 时自动回退 debug 签名（仅自用可安装；商店/公开分发必须自建 keystore）。
- 自建方法见 `dsh-mobile-app/README.md`「构建」一节。
- ⚠ 更换签名 = 新应用：用户需卸载重装并重新扫码。
