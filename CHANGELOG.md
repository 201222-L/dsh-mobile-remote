# Changelog

## v2.4.1（2026-08-16）— 外出访问：多地址自动切换

### 新增
- **多地址自动切换**：App 连接成功后自动从电脑收集全部地址（局域网 IP + Tailscale IP，`/api/bootstrap` 的 `server.urls`），断线重试失败时自动轮换——出门自动切 Tailscale、回家自动切回局域网，全程免手动配置
- 设置 → 电脑地址显示「共 N 个地址自动切换」

## v2.4.0（2026-08-16）— 问询/审批弹窗 + 兼容性硬化

### 新增（移动端补齐"人类交互"）
- **问询弹窗**：agent 用 `ask_user_question` 提问时，手机对话页弹出卡片（单选/多选选项 + 自定义输入），与 PC 端**同一 pending 通道**，任一端回答两端同步消失
- **权限审批弹窗**：工具越权时手机弹出「权限请求」（工具名 + 原因 + 允许一次/拒绝）
- 弹窗桥：插件 `ctx.inject(["apiProxy"])` 订阅 mux 队列（PC GUI 同机制），SSE `mobile/frame` 帧转发，断线重连补发挂起待答帧
- `/m/api/respond` 应答端点（question/approval/cancel），经 `apiProxy.respond` 走内核校验
- **通知删除**：长按单删 / 垃圾桶批量多选 / 清空全部（`/m/api/notifications/delete`，不影响 PC 端）
- **微信式无限上翻**：滑到顶部自动加载更早（无断页）；「回到底部」浮钮
- 余额旁独立刷新按钮（移除点击数字刷新的旧交互）；应用日志默认 15 天清理
- 顶部抽屉与标题间电脑在线状态点（点按探测/重连）
- 诊断探针：`services` 全量服务探测 + `respondBridge`/`frameBridge`/`pendingFrames`

### 修复
- **问询/审批桥拿不到 apiProxy**：各插件上下文隔离，`ctx.get` 看不到兄弟插件服务 → 改用 `ctx.inject`（dsh-client-connection 同款）
- 手机点 ✕ 取消后卡片不消失（本地状态提前清空导致 resolved 帧被跳过）→ 即时收起 + 无条件转发
- 聊天初始化竞态：SSE 事件与历史加载并发时不再丢失/回退 lastSeq
- 历史页加载不再污染正在流式生成的草稿

### 硬化
- `webServer` 守卫：纯 headless Harness 下插件静默无操作不崩进程
- Release 签名：正式 keystore（gitignore）+ key.properties 自动回退 debug
- 渲染后端定版 **Impeller**：此前"小米白屏→回退 Skia"系旧列表实现误判，深滚动在 Impeller 下完全正常（Skia 分段模式保留为 `_infiniteMode=false` 兜底）

## v2.1.0（2026-08-15）— 开源准备

### 新增
- **桌面设置页「连接移动端设备」**：dsh 客户端模块，显示扫码二维码（含地址+口令）+ 连接信息（`/m/api/qr-config`，仅 loopback）
- **原生 Flutter App**（`dsh-mobile-app/`）：扫码连接、首页/对话/会话/通知/设置/新建会话全原生界面，DeepSeek 配色双主题
- **修改默认配置**：默认 Agent 预设 / 默认权限预设可直接在移动端修改（`POST /m/api/defaults`，与 PC 端同一写入通道）
- **通知聚合**：同一会话同一类型通知合并，不再按轮次刷满列表
- **工作区归属**：新建会话 cwd 为已注册工作区子目录时自动归属最近工作区（不再落"未分组"）
- App：深色模式三态切换、环境诊断时间戳、返回键层级处理、长任务排队提示

### 修复
- **SSE 解析死循环**（buf 在循环内不更新导致 CPU 100% 卡死）—— 重写为 StringBuffer 增量解析
- App 通知页黑色背景（独立页面缺 Scaffold）
- App 消息重复显示（SSE 回显按 messageId 优先去重）
- App 目录选择器无限加载（初始化未触发）
- App 通知角标 Positioned 崩溃、HTTP 客户端泄漏、流式渲染风暴
- 小米设备 Impeller+Vulkan 白屏/卡顿（回退 Skia）
- 消息文本去重、首页文案、链接复制等细节

## v2.0.0 — 移动端 v2（新建会话 / 目录 / 通知中心 / 诊断 / 余额）

- 新建会话：Agent 预设 + 模型/推理/权限 + 工作目录（跨盘浏览、新建文件夹）
- 通知中心：已读持久化（文件存储）、未读角标
- 环境诊断、余额查询、插件动作区、SSE 事件桥（重连退避/断线补拉）

## v1.0.0 — 移动端 v1（MVP）

- `/m` 移动页：登录、发消息、SSE 流式、会话历史
- 访问口令认证（cookie/header）、Host 校验、二维码
- 推送桥：Server酱 / ntfy / Bark / generic
