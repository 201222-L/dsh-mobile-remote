# Changelog

## v3.0.0（2026-08-22）— LAN 桥：桌面版局域网直连（无需穿透）（二次 Code Review 落实集成于本版本内）

### 队列"发送出去/删不掉"修复（移动端 ↔ 内核队列一致性）
- **根因三层**：① 内核语义——`followup` 只入 `next-turn`,当前 turn 结束的瞬间 agent 循环即开新 turn 认领(与 PC 端一致,非 bug);② App 丢弃内核权威 `session/queue` 帧(`store.dart` 只处理 question/approval),dock 全靠 400ms 节流 REST + 20s 轮询,存在陈旧窗口——消息已被认领行仍显示;③ 删除 TOCTOU——被认领后内核返回 `queue-item-not-found`,而 `ApiException` 不带错误码,无法区分语义
- **服务端**:mux 把 `session/queue` 归一化为 **`mobile/queue` 帧**(`{sessionId, rows:[{id,text,placement}]}`,与 GET /queue 同款形状),认领/删除/编辑即时镜像;LAN 桥 SSE 空闲超时从"完全取消"收窄为 **60s**(>25s 心跳,防误杀且保留僵尸回收)
- **App**:`store` 新增 `queueBySession` 镜像 + **帧权威**策略(帧永远覆盖,REST 仅无帧可依时兜底,防止旧 REST 快照覆盖新帧);chat dock 以帧为权威源——被认领瞬间行消失;删除/插话/编辑失败按 `queue-item-not-found` / `steer-unavailable` **语义化提示**;`ApiException` 增加 `code` 字段
- **悬浮球**:SSE `readTimeout 0→50s`(插件 25s 心跳保活,静默死链 50s 内自动重连,通知不再断供);`markNotif` 收敛主线程(消 SSE 线程/主线程并发丢计数);`placePanel` 判空守卫 + onDestroy 取消面板动画/置空 panelParams(修 after-destroy `updateViewLayout(null)` 主线程 NPE 杀进程)

### 二次 Code Review 落实
- **必改**:`md.dart` 列表/表格后段落乱序(`- a\n- b\nprose` 把 prose 渲染到列表上方);`notifications_screen` await 后补 mounted 守卫(pop 后 setState 崩溃);`sheets` 新建会话/文件夹 **busy 锁**(双击双建)+ 文件夹名 Windows 非法字符前置校验
- **中低**:`logger` 去每行 fsync(SSE 流式期间掉帧),文件体积改近似记账;`_MsgItem.copyWith` 显式断言(防未来复用静默变用户消息);`agent/status` child 注释缩进
- **文档**:03-api §3.6b 帧表更新(`mobile/queue` 独立行,`mobile/frame` 收窄为问询/审批)

### 验证
`flutter analyze` 0 issues;`flutter test` 9/9;`node --check` 通过;版本不变(pubspec `3.0.0+5` / package.json `3.0.0`,与既有版本线一致)。

### 背景
DSH Desktop（0.1.1-rc.2 / v2.0.2）强制 webserver 只听 `127.0.0.1`——`dsh-plugin-desktop` 在 profile 组装时把 webserver 行替换为 `DesktopWebServer`（构造器对非回环 host 直接 throw，用户 patch 无法覆盖，唯一旋钮是端口），手机无法直连桌面版。旧版（rc.5 web profile）能 `0.0.0.0:3080` 所以手机可连。

### 新能力：插件内置 LAN 桥（`lanBridge` 配置，默认关闭）
- 插件在 DSH 进程内**自建第二个 HTTP 监听**（默认 `0.0.0.0:3080`），把 `${path}`（默认 `/m`）前缀请求**流式转发**到回环 webserver——手机填/扫 `http://<电脑局域网IP>:3080/m` 即可使用，**无需穿透、无需装任何工具、不改 DSH**（桌面版/web 版通用）
- **安全边界**（代码强制）：
  - 只转发移动端面（`/m/*`）；桌面 `/api` RPC 网关、`/m/api/qr-config`（含 token）、`/m/qr.png`（仅本机语义）一律 404 不转发 —— 桥不扩大桌面攻击面
  - 未配置 **authToken 拒绝启动**（LAN 暴露必须强口令，docs/04-security.md）
  - Host 头重写为回环信任值 → 下游 hostAllowed 自然放行；真实鉴权仍由 token 把关
- **扫码/自动地址联动**：`lanBridge` 启用时 bootstrap `urls` 与桌面二维码（qr-config）首选地址自动变为桥地址（`http://<IP>:3080/m`），App 扫码即连，无需手动填
- 诊断：`/m/api/diagnostics` `runtime.lanBridge` 上报 `{enabled, host, port, listening}`；插件日志打印监听状态与错误
- 清理：插件卸载时桥随 effect 关闭

### 配置（cordis.patch.yml，用户侧）
```yaml
lanBridge:
  enabled: true
  port: 3080        # 冲突可改；防火墙需放行该端口
  host: 0.0.0.0     # 默认全接口；仅本机测也可用 127.0.0.1
```

### 三路全量 Code Review 修正（2026-08-22）
- **服务端（23 项，0 CRITICAL/0 HIGH）**：桥加固——只转发 `/m/api*`（收窄原 `/m/*`）、`maxConnections=128`、headersTimeout 15s/requestTimeout 60s、upstream 15s 超时、剥离 `x-forwarded-*`/`via`、在网 socket 随卸载销毁；QR/bootstrap 地址按**实际监听成功**判定（绑定失败回退回环，不指向死端口）；`/llm-providers` POST 直调 `settings.mutate/credentials.set` 显式 try/catch（不再裸抛落 500）；`/notifications/read|delete` 与 `/sessions/touch` 写盘**去抖**（500ms/10s，卸载前冲刷）；`/notifications/delete` ids 限 500；`/history before=0` 语义修正；`/goal maxGoalRounds` 校验 1-10000；`/send` followup/steer try/catch；**authToken 弱口令全局告警 + 桥强制 ≥16 拒启**；lanBridge schema 校验 port/host
- **App（17 项，1 HIGH）**：**HIGH 修复——页级动作统一 `_mySessionId`**（发送/停止/杀任务/消息操作/用量/命令菜单/工具页，叠层聊天不再发错会话）；余额成功清错误态；通知页错误态+store 联动实时刷新；SSE 连接窗口内晚到响应取消（半开 socket 修复）；深色模式链接品牌色；气泡解析缓存含亮度；`_decode` 非 JSON 兜底；`commands()` 区分 unavailable；analyze 唯一 info 消除
- **Kotlin/文档（21 项，0 CRITICAL）**：Android 13+ 运行时请求 POST_NOTIFICATIONS；httpGet 补 readTimeout；Android 14+ 三参 startForeground 显式 SPECIAL_USE；addView 悬浮窗权限兜底；明文 HTTP 残余风险注释；**文档同步**——04-security 新增 §3b LAN 桥安全边界、09-compatibility 更新 0.1.1-rc.2 基线矩阵与配置项、README/06-install-run 版本、03-api 补 LAN 桥地址说明、AGENT-RULES 维护公告更新；版本三处统一（pubspec 3.0.0+5）

### 未推送说明
功能开发、全量评审修正已完成,并通过 PC 侧与真机（App 局域网实测）验证；**待本机全部复验通过后由用户决定推送**。

## v2.8.2（2026-08-22）— 适配 DSH 0.1.1-rc.2（DSH Desktop v2.0.2）

### 服务端（lib/index.js）
- **CRITICAL 修复：`rpcError` 返回改为 `[status, code, message]` 元组**。调用展开 `error(res, ...rpcError(...))` 走迭代器协议，普通对象字面量与 `Object.create(null)` 均不可展开——**2.8.1 起全部 11 处 API 错误路径（队列/归档/fork/取消/模型/子代理/命令/goal）抛 `Spread syntax requires ...iterable[Symbol.iterator]`**，该 TypeError 上抛到 `handleApi` 外层 catch，统一退化为 `500 { error: "internal" }`，真实状态码/内核错误码/详情全部丢失。已实测复现（修复前 `500 internal` → 修复后 `400 session-not-found + detail`）
- **错误码收窄为仅非空 string**：内核自定义错误码是契约字符串（`session-not-found` / `target-not-found` 等）；`DOMException.code` 等数字码不在契约内 → 落 fallbackCode（注释记录依据）
- **GET `/m/api/commands` 拆分条件**：`commands` 服务未注册 → `200 { ok, commands: [], unavailable: true }`（优雅降级，App 端弹「无可用命令」，不硬 503）；服务在而会话不存在 → `404 session-not-found`（不再被空列表掩盖真实原因）
- **POST `/m/api/commands` 适配内核四参签名**：`commands.execute(agent, line, images, signal)`（0.1.1-rc.2；2.8.1 旧三参调用会把 `AbortSignal` 误传 `images` 槽，已改正）；`images` 恒为空数组，`signal` 15s 超时；未知/畸形命令仍 `404 command-not-found`，服务缺失 `503` 附 detail；同样拆分 `!agent` → `404 session-not-found`（与 GET 一致）
- 文档：03-api.md 补 §6.15 斜杠命令契约与端点总表行（2.8.0 引入时遗漏）

### 验证
- 修复后实测（DSH Desktop v2.0.2 / 0.1.1-rc.2，真实会话）：archive/fork 假会话 → `400 session-not-found + detail`；goal pause 无目标 → `400 no-active-goal`；feedback none 幂等 200 / positive 不存在消息 → `404 target-not-found`；commands GET 真会话 200 真实列表、假会话 404、POST `/goal` 200 真执行结果、`/bogus` 404、非斜杠 400 —— 全量通过
- 三路 Code Review（服务端两轮：首轮发现 CRITICAL、复核通过 PASS；App 全量零改动）并修复发现项；App 侧维持 v2.8.1

## v2.8.1（2026-08-22）— 消息操作栏 + 输入栏重构 + 命令入口 + 反馈增强

### 消息操作栏（替代长按）
- 助手消息下方**常驻操作栏**：复制 / 好的回答 / 有问题的回答 / 在新对话中分支——对齐 PC 端 `MessageIconActions`，点即用；**移除长按弹底部面板**
- 操作逻辑抽为 `_runMessageAction` 统一处理（复制/反馈/分支），无重复代码

### 反馈增强（对齐 PC 端）
- 👍/👎 选中态 = **品牌蓝图标 + 浅蓝圆底**（PC 端 `data-active` 同款样式，positive/negative 同色）
- **toggle 取消**：再点已选评级 = 取消反馈（服务端新增 `rating: "none"` → 内核 `messageFeedback.delete`，与 PC 端一致）
- 反馈状态按 messageId 同步 live 列表与历史页；同消息提交中防连点竞态

### 输入栏两层重构（对齐 PC 端 InputBar）
```
第一层: [输入框························]
第二层: [⊕] [模型…] [权限…] [排队发送] [⭕] [发送]
```
- 模型/权限胶囊移到第二层，名称省略显示（超长截断，保证放得下）；排队胶囊固定宽度不被挤压；上下文圆环/发送按钮在弹性组外固定，任意窄屏不溢出
- 深色主题适配（⊕ 图标不再黑压黑）

### 命令入口
- 第二层新增 **⊕ 命令按钮**（浅灰圆，对齐 PC 端 command）→ 弹命令列表 → 点选 `/命令名 ` 填入输入框（PC 端 leadingInput 语义，可补参数后发送）
- 服务端新增 `GET/POST /m/api/commands`（对齐内核 `ctx.commands`：`list(agent)` / `execute(agent, line, signal)`）；未知/畸形命令返回 404 `command-not-found`

### 其他
- 版本号统一 2.8.1（插件 2.8.1 / App 2.8.1+4）
- 全部改动经三路 Code Review（服务端/Flutter/Kotlin）并修复发现项；命令功能在测试窗口会话端到端实测通过

## v2.8.0（2026-08-22）— 代码收敛重构（Phase 0/1/2，行为保持）

### 服务端（lib/index.js）
- **Phase 0 公共 helper**：新增 `agentSessionId` / `isLoopback` / `firstAgent` / `shortSessionId` / `notifyTitle` / `guardRes` 六个 helper，统一散落各处的重复写法（会话 id 归一、回环判定、标题兜底短码、响应防崩守卫）
- **Phase 1 三收敛**：
  - `readJson(req, res)` 收敛 20 处 `JSON.parse(await readBody(req))` + try/catch 样板（失败统一 400/413 响应）
  - `rpcError(err, code)` 收敛 9 处 apiRpc 失败映射（传输层 502 / 超时中止 504 / 内核错误透传 status+code）
  - `requireGet` / `requirePost` 收敛 29 处 405 方法检查；`/events` 保持严格 GET-only（HEAD 会悬挂 SSE 连接）
- `/sessions` 列表标题统一兜底短码（live 与归档分支一致，标题永不裸 null）

### 悬浮球（FloatingBubbleService.kt）
- 新增 `baseUrl` / `httpGet` / `postState` / `openApp` / `roundedRect` / `isActive` / `isBusy` 七个 helper：统一 HTTP 请求骨架（含 finally disconnect）、主线程刷新、跳转、圆角背景、状态判定
- `mainIntent` 统一前台通知与面板跳转的 Intent 构造（extra 类型守卫：String/Boolean/Int，成对传参）
- 清理 3 个未使用 import；未读增量检查失败不再消费首次基线（消除瞬时失败误报）

### App（Flutter）
- 新建 `lib/fmt.dart`：`relTime` / `fmtTokens` / `permNameOf` 共享格式化（首页/会话页/聊天页/设置页收敛）
- `toast.dart` 新增 `showToastAt(messenger, msg)`：sheets/settings 的本地 `_toast` 全部收敛
- `theme.dart` 新增 `DshSwitch`：设置页三处开关统一
- `openChat`（chat_screen.dart 顶层）统一 7 处打开会话流程（含悬浮球/新建/分支，返回后恢复语义保持）
- `openNotificationsScreen`（main.dart 顶层）统一 3 处通知页入口；`openProviders`（providers_screen.dart）统一 2 处提供商页入口
- `_persistPrefs` 收敛 8 个 setter 的 SharedPreferences 样板（不支持类型快速失败）；`_isNoiseText` 收敛消息噪声过滤；删除死代码 `api.events()`
- 行为变化说明：assistant 消息现在与 user 消息一致地过滤 `background job ` 前缀注入帧（与 PC 端 GUI 对称）

### 其他
- 版本号统一 2.8.0（package.json / pubspec 2.8.0+3）
- 纯收敛重构 + 少量 UI 修正，全部改动经多轮 Code Review
- **UI 行为变化（v2.8.0 修复）**：
  - 对话消息列表统一为普通列表（最旧在顶、最新在底）：消息少时内容贴顶、列表占满可滚动——修复旧版"下半部分空白死区 + 滑动消息消失"；根治 50/51 条边界列表方向翻转的滚动位置跳变
  - 输入框胶囊行：容器内边距对称、胶囊行与输入框左缘对齐；模型胶囊超长省略号截断（防溢出）；插队按钮图标由播放三角改为右向箭头
  - 悬浮球余额自查：JSON 解析兜底 try/catch（200 但畸形响应体不再产生异常噪音）

## v2.7.2（2026-08-21）— 通知改"真结束"判定 + 悬浮球横屏修复

### 通知（服务端 + App/悬浮球同源）
- **只在对话真正结束时通知**：多轮大任务（goal 驱动/连续队列）不再每完成一个子轮次就推"✅ 任务完成"——`turn/end` 只暂存结果，agent 转为 idle 且稳定 `doneGraceMs`（默认 15 秒，插件配置可调）、且无 active goal，才判定"对话真正结束"并通知一次
- **子代理会话不再单独通知完成/失败**：它是父任务的一部分，父任务结束才通知；「需要你回答」仍立即通知（交互式提问不能等）
- **通知帧直推 SSE（`mobile/notify`）**：悬浮球/App 与插件通知中心同源渲染，悬浮球不再自行按轮次/job 弹"任务完成"
- max-tokens 截断的完成通知会标注「max-tokens 截断」，避免误以为任务完整完成
- **审批/提问提醒补全**：`approval/requested`、`question/requested` 立即生成 `needs-answer` 通知 + 推送桥（App 后台/被杀、悬浮球未开时也能收到）；悬浮球提醒统一由 `mobile/notify` 驱动（与弹窗帧去重，不再双弹）

### 修复
- **修复崩溃级 bug**：`mobile/notify` 广播中 shorthand `{ time }` 引用未声明变量（漏写 `time: now`）→ 每次通知都抛 ReferenceError，`armDone` 定时器异步回调中的异常在 Node 15+ 默认按 unhandledRejection 抛出 → **整个 DSH 进程崩溃**；已修正并给定时器回调整体加 try/catch 兜底

### 插队发送
- `/send` 端点新增 `mode: "steer"` 参数：插队发送（消息插到 agent 下一步执行），适合 team 插件子会话向主会话插队场景；agent 空闲时自动降级排队并在响应中标注
- 手机端：**长按发送按钮 = 插队发送**；agent 空闲时提示并降级普通发送

### 悬浮球横屏修复
- **旋转/跳转后无条件自动贴边**：监听配置变更（`onConfigurationChanged`），按旋转前渲染位置（`lastRenderX`）判断贴左/贴右、保持隐藏状态——竖屏↔横屏、翻转 180°、页面跳转后球都自动回到边上，无需手动拖动
- **挖孔/安全区偏移适配（关键修复）**：横屏时系统会把 overlay 窗口整体平移（本机挖孔屏 ROTATION_90 时右移 144px），不扣除偏移会导致球被推到屏幕外"消失"（翻转 180° 后更会稳定消失）。实测 `rootWindowInsets` 在 overlay 窗口上返回值不可靠，改用 **display 级权威数据 `defaultDisplay.cutout`**（API 29+）读取安全区，所有贴边/拖动/面板/气泡定位统一按"渲染坐标 = 坐标 + 系统偏移"计算
- **拖动钳制**：x 限制在 `[-球径+16dp, 屏宽-16dp]`、y 限制在屏内（按渲染坐标钳制）——永远拖不出屏、不会进入无法恢复的位置
- **自愈兜底**：按下时发现越界先钳回允许范围再开始拖（覆盖部分厂商不回调配置变更的情况）
- 屏幕尺寸获取 API 30+ 改用 `currentWindowMetrics`（旋转后最可靠）

### 其他
- 版本号统一 2.7.2（package.json / pubspec 2.7.2+2）

## v2.7.1（2026-08-18）— 稳定性修复 + 悬浮球余额预警完善

### 修复
- **会话列表慢（归档/取消归档后要几秒才生效）**：休眠会话标题折叠结果**缓存 5 分钟**（折叠需逐个读日志，50+ 会话实测 7 秒）+ App 端**乐观更新**（归档后本地列表立即生效，后台静默校准）——实测归档请求 29ms、列表刷新不再卡
- **通知逐条保留**：每次轮次完成（主会话/子代理各自）独立生成一条通知，互不合并——已读的消息不再被后续轮次顶掉（去掉旧"同会话同类型聚合覆盖"）
- **Agent 状态串台**：状态改为按会话绑定（`agentStatusMap`，bootstrap 全量同步 + 帧按 agentId 过滤）——切换工作区/回前台/打开会话时状态圆点与停止按钮不再显示成别的会话的；重连 `hello` 帧与重试 bootstrap 也同步状态
- **悬浮球不再常亮**：余额低不再是"常亮状态"，改为事件式提醒（亮 60 秒自动消退 + 30 分钟防抖）
- **顶部通知横幅彻底重写**：弃用 `OverlayEntry`（新版 Flutter 下 remove 后视觉残留，横幅挂住不消失）——改为 `MaterialApp.builder` 全局渲染（覆盖所有页面，含聊天页/通知页）；**回前台/悬浮球跳转时若有未读则强制提醒**（"错过的也提醒"，绕过防抖）；显示后自动更新未读基线不反复弹
- **新建会话弹层补回「模型与推理强度」入口**：显示当前模型 + 强度，点击弹出模型/推理强度（off/high/max）选择——v2.7.0 首页改版时该入口遗漏
- **新建会话工作目录自动匹配当前工作区**：改用规范化路径匹配（此前 `api.workspaces()` 原始路径与 workspacePath 大小写/斜杠不一致，永远回退第一个工作区）

### 悬浮球余额预警（App 端为准）
- **阈值可配置**：设置 → 账户 → 余额预警行点击选择 ¥5 / ¥10 / ¥20 / ¥50 / 自定义输入，持久化；副标题实时显示当前阈值
- **开关联动**：悬浮球的报警判定**完全以 App 端开关 + 阈值为准**（开关/阈值变化即时推送，App 启动时同步）——开关关 → 悬浮球不因余额报警/亮起
- **面板常驻余额行**：两位小数（`余额 ¥12.50`），低余额红字（静默警示，不亮球）；点击可去充值
- 面板打开时顺带刷新余额；30 分钟自查照常更新数值

### 悬浮球面板与徽标
- **未读徽标胶囊化**：球上角标与面板通知区徽标均为胶囊形（圆角=高一半），单数字也保持胶囊比例；球上角标骑在球右上外缘（不再偏下）
- **面板空状态**：无运行中会话 / 无通知时显示灰色占位文案（「暂无运行中的会话」「暂无通知」），面板不再空荡荡
- **通知区标题行对齐**：最近通知 / 未读徽标 / 查看全部 三者文本视觉中心统一（去字体留白 + 垂直居中）

## v2.7.0（2026-08-18）— 会话工具（任务/子代理/目标）+ 移动端体验打磨

### 新增（移动端会话工具，PC 端 GUI 同源数据）
- **任务进度**：会话运行中的后台任务（jobs）实时推送（SSE `session/jobs` 帧，连接回放 + 订阅更新），对话页活动条下方自动出现任务卡片（状态点/标签/取消）；AppBar 新增「会话工具」入口
- **会话工具弹层**（任务 / 子代理 / 目标 三页签）：
  - 任务：列表 + 取消（映射内核 `jobs.kill`，按会话隔离）
  - 子代理：按父会话查询子代理列表（`subagent.list`）+ 中断（`subagent.interrupt`）
  - 目标：查看当前目标（objective / 轮次 / 状态）、创建、暂停 / 继续 / 标记完成（映射内核 goal RPC，`sessionId + ref` 契约一致）；受阻时显示原因
- **插件新端点**：`/m/api/jobs`（GET）、`/m/api/jobs/kill`（POST）、`/m/api/subagents`（GET）、`/m/api/subagents/interrupt`（POST）、`/m/api/goal`（GET/POST）；连接回放 `session/jobs` 帧，`onJobsChanged`/`onJobDone` 订阅随插件卸载清理

### 新增（移动端体验）
- **Agent 状态 bootstrap 同步**：连接 / 重连 / 下拉刷新时从 bootstrap 同步 agent 状态（思考中 / 工具执行 / 空闲），按钮与活动条即时反映 PC 真实状态
- **下拉刷新收集地址**：refreshAll 吸收 bootstrap 的 `server.urls`（蒲公英 / Tailscale 等新地址及时进候选表，回环地址过滤）
- **聊天草稿保留**：会话级缓存，输入内容退出会话后重进自动恢复（仅内存，不落盘）
- **首页改版**：移除底部快捷输入框（模型/权限选择移至新建会话弹层与会话页）；欢迎语改为「今天打算设计什么？」；顶部展示 DeepSeek 官网官方 logo；内容块整体上移居中；最近会话卡片固定 3 行完整显示、超出卡片内滑动
- **界面语言切换**：设置 → 显示 → 语言（中文 / English），即时生效、持久化；主要界面全量双语（首页 / 会话 / 聊天 / 设置 / 连接 / 通知 / 会话工具弹层 / 提供商管理页等）
- **悬浮球（设置 → 显示，默认关）**：透明底圆形 DeepSeek 鲸鱼常驻桌面（App 被杀仍工作，自带 SSE）
  - 状态：空闲=灰鲸半透明；有任务/通知/余额低=亮蓝 + 红点角标（60s 自动消退、开面板清零、同类防抖）
  - 交互：单击展开迷你面板（运行中会话 / 最近通知 / 打开 App / 去充值）、拖动贴边 5s 无操作自动缩进、双击开 App、长按退出
  - 面板：四角定位（随球位置向内展开）、点击外部关闭、SSE 事件即时刷新 + 5s 兜底、无内容区块隐藏、浅灰胶囊按钮
  - 动效：按压缩放回弹、滑动吸附、亮暗 180ms 过渡、面板从球方向生长 + 逐项浮现
  - 余额联动：悬浮球每 30 分钟自查余额，低余额亮起 + 气泡 + 按钮变红
  - 面板通知区：最近通知（上限 3 条）+ 红色未读徽标（与 App 铃铛同源）+ 未读蓝点 + 相对时间 + 查看全部入口（点击跳 App 通知页）
  - 操作说明：设置页「悬浮球操作说明」弹窗（状态含义 / 手势 / 面板操作，双语）
- **余额预警（设置 → 账户，默认关）**：余额低于 ¥10 提醒充值，余额行红色警示
- **充值入口**：跳转系统浏览器打开官方充值页（恢复 v2.6 原方式；小米不支持标准 Custom Tabs，已移除相关代码）
- **通知提示（错过的也提醒）**：悬浮球每 60 秒 + App 每次刷新对比未读数增量——重连窗口 / 离线期间新增的通知，重连后**亮红点 + 气泡「有 N 条新通知」+ App 顶部横幅**（点击跳通知页），不只静默更新数据

### 设计风格与动效
- **主题令牌统一**：卡片圆角 14 / 弹层 20 / 输入框 10；阴影弱化为单层轻投影（浅底+细线+极轻投影分层）
- **页面转场**：轻量 iOS 味（新页全宽滑入 + 淡入，旧页静止零重绘——解决 Cupertino 双页面渲染卡顿）
- **通知铃铛实时刷新**：轮次结束 App 主动拉取通知（不依赖重连/下拉），插件写入通知后广播 `notifications/changed`

### 修复
- 任务四端点契约对齐内核 schema（`subagent.list` 需 `parentSessionId`、`subagent.interrupt` 需 `parentSessionId + childSessionId + mode`、goal 变更需 `sessionId + ref`；goal POST 的 agent 解析改用 body 的 sessionId）
- 目标页「无目标」状态不再卡加载（服务端 `goal: null` 与加载中区分）
- 目标操作后无论成败都刷新真实状态（轮次驱动可能已改变状态，如轮次耗尽→受阻）
- 会话工具弹层旧插件降级：端点不存在时显示「加载失败 + 重试」而非白屏
- **休眠会话标题**：重启 / 重连后历史会话直接显示标题（`sessionQuery.readTitleSnapshot` 从持久化日志折叠），无需点进去才更新
- **通知聚合重新未读**：同会话同类型通知聚合时从已读集合移除——已读后同会话的后续完成会重新触发未读（修复角标/提示永久不亮）
- 悬浮球：空闲检测不再被红点卡住（轮次边界驱动亮暗）、连接回放不误报通知、右半屏点击、贴边缩进（`FLAG_LAYOUT_NO_LIMITS`）、气泡按实际测量宽度定位（修复硬编码宽度致窄气泡飘到屏幕中间）、面板实时同步
- 通知写入后广播 `notifications/changed`（App 铃铛实时更新，无需重开 App）
- 悬浮球开关语义：`START_NOT_STICKY` + 余额推送仅在服务运行时生效（开关关着不再被系统复活 / 余额刷新拉起）

### 兼容
- 新增端点与 SSE 帧：旧 App 忽略新帧；旧插件无新端点（App 弹层提示加载失败，升级插件后可用）
- 首页移除底部输入框为**行为变更**：首页发消息改为「＋新建会话」入口（会话页输入不受影响）
- 已发布 API 无破坏性变更

## v2.6.0（2026-08-17）— 安全加固 + 移动端过程可见性 + 模型提供商互通

### 新增（安全）
- **登录失败限流**：`rateLimit` 配置（默认 10 次/60s），错误口令按来源 IP 计数，超限返回 `429 rate-limited` + `Retry-After`；认证成功重置计数——防弱口令爆破（仅 `authToken` 启用时生效）
- **推送内容脱敏（默认开启）**：第三方推送通道（Server酱/ntfy/Bark/generic）默认只推事件类型 + 会话短码，**会话标题、错误详情等核心内容不再外发**；确需完整内容设 `pushContent: "standard"`（旧行为，仅在信任通道时开启）
- **链接 scheme 白名单（App）**：消息内链接仅 http/https 可点击，`file:`/`intent:`/`tel:` 等一律渲染为纯文本（含单元测试 `test/md_link_test.dart`）
- **`/m/qr.png` 收口本机**：与 `qr-config` 同策略（Host 校验 + loopback 来源），不再对外提供无认证二维码渲染
- **口令比较加固**：改为 sha256 定长化 + 常量时间比较，消除长度侧信道
- **认证未启用显性警示**：插件启动日志告警 + 桌面设置页红色横幅「访问口令未启用」
- **Android 备份隔离**：`allowBackup="false"`，口令/缓存不进云备份与 ADB 备份
- **桌面设置页复制口令 60s 自动清剪贴板**（防其他应用读取；尽力而为）

### 新增（移动端过程可见性）
- **思考过程实时显示**：agent 思考时对话页出现可折叠「思考中…」面板，实时滚动思考内容（点开/收起），正文开始后显示「已思考 N 字」
- **活动条**：思考 / 工具执行阶段在输入框上方显示轻量状态行（如「正在调用 read…」），结束即消失——不再"干等无反应"
- **移除「显示工具调用」开关与工具卡片**：工具过程统一由活动条呈现，设置页与代码同步清理（工具结果细节以 PC 端为准）
- **「思考内容」开关（设置 → 显示）**：默认关——只显示思考状态（思考中/已思考 N 字），不显示思考原文（deepseek 思考内容为英文，默认隐藏防刷屏；需要时打开）

### 修复
- generic 推送格式 `kind is not defined`（存量 bug，仅 generic 通道触发）
- `z.enum` 不兼容 schemastery 导致插件加载失败（v2.6 新增配置项改用 `z.string` + 运行时校验）
- **移动端消息重复显示**：SSE 回显先于 send 响应到达（且轮次分隔线已插入）时，乐观消息合并失败 → 同一条消息显示两次；改为全列表查找乐观消息合并
- **工具阶段空气泡**：多步工具轮中正文为空的中间 assistant 消息不再渲染（过程由活动条呈现）
- e2e-check：支持 `DSH_MOBILE_BASE` 环境变量、无 agent 实例自动跳过发送

### 新增（模型提供商互通，PC × 移动端）
- **模型提供商互通**：PC 端「设置 → 模型」配置的提供商与移动端同一通道，**两端一致、手机修改即时生效**
  - 内核 `llm` 服务的可配置提供商目录全量上手机：除 deepseek-official 外，**37 个 dormant 提供商**（anthropic / openai / google / groq / mistral / nvidia / openrouter / xai / kimi / minimax / moonshotai / qwen / zai / xiaomi 等）在手机可见，配置 baseURL + API Key 即激活
- **插件新端点**（`/m/api/llm-providers` GET / POST、`/m/api/llm-providers/probe`）：
  - 提供商列表（live/dormant、settingsNs、baseURL、密钥状态——密钥引用只读，**不返回密钥本身**）
  - 保存：`ctx.settings.mutate` 写配置 + `ctx.credentials.set` 存密钥（引用派生规则与 PC 端一致：`<PROVIDER>_API_KEY`）；仅允许写入配置目录声明的命名空间
  - 探测：优先内核 `discoverModels`；内核未注册模型探测时（rc.5 deepseek 适配器）**回退 OpenAI 兼容 `GET {baseURL}/models`**
- **App**：
  - 模型选择器**按提供商分组**（组名 = 提供商显示名），dormant 提供商显示「未配置」不可选
  - 设置新增「模型提供商」管理页：列表（已连接/未配置徽标 + baseURL + 密钥状态 + 目录模型数）、编辑（baseURL / API Key / 探测模型 / 清除密钥）
- catalog 新增 `providers` 元信息；`session-config` 返回当前模型所属 `provider`；无 agent 兜底目录改为遍历全部提供商（不再写死 deepseek-official）
- `llm.listProviders()` 等为同步方法，原 `.catch()` 链式调用抛错（端点改用 try/catch）

### 文档
- 06 新增「HTTPS 反代」章节（Caddy/nginx + 自签证书，可选 TLS 方案）
- 03 新增 §6.13 模型提供商端点；04/09/00/07/README 同步：限流参数、429 错误码、推送脱敏、链接白名单、备份说明、提供商互通

### 兼容
- `pushContent` 默认 minimal 为**行为变更**：升级后推送内容变精简（通道配置无需改动，如需完整内容显式设 standard）
- 移除「显示工具调用」为**行为变更**：移动端不再显示工具结果卡片，工具过程以活动条呈现
- 旧 App 忽略 catalog 新增字段；旧插件无新端点（App 管理页提示加载失败，升级插件后可用）
- 已发布 API 无破坏性变更；`rateLimit` / `pushContent` 均为新增可配置项

## v2.5.2（2026-08-17）— 抽屉与弹层溢出修复

### 修复
- **工作区过多时抽屉挤出「设置」入口**：工作区列表改为封顶屏高 35% 的可滚动区，导航三项（首页/会话/设置）固定在可见区域，不再被顶出屏幕（感谢社区反馈与 PR #1 的思路）
- **底部弹层条目过多溢出**：通用底部弹层与「新建会话」弹层的列表区改为可滚动，底部按钮固定
- **切换连接地址弹层溢出**：候选地址随使用动态累积，列表区改为可滚动（同类隐患全库排查后修复）
- **agent 问询卡片挤压输入框**：问题说明长/选项多时卡片封顶 40% 屏高内部滚动
- **连接配置页键盘溢出**：表单整体可滚动，小屏 + 键盘弹出时不再溢出

## v2.5.1（2026-08-17）— 连接自愈提速 + 版本线统一

### 版本线统一（重要）
- **App 版本 = 插件版本 = git tag**：插件 2.4.1 对齐为 **2.5.1**，此后每次发布三处一起 bump
- GitHub Release 每版同时提供 `DSH-Remote-vX.Y.Z.apk`（App）+ `dsh-mobile-remote-vX.Y.Z.tgz`（插件包）
- 版本差矩阵见 README「版本与兼容」（同版本完美；不同版本可用但"谁旧谁吃亏"）

### 修复/优化
- **黑洞地址快速故障切换**：手机关组网/隧道断时，从约 72 秒缩短到**约 10 秒**自动切到可用地址（SSE 超时即轮换 + 连接/探测超时 15s→8s）
- **下拉刷新升级**：改为「探测 → 自愈 → 拉数据」——先探测连通性，不通自动轮换地址并重建连接；失败弹短提示「电脑连接不上，正在自动重连…」（成功静默）
- 文档：蒲公英手机端保活设置（国产 ROM 杀后台是外出断连头号原因）；安装依赖补充 `github:` 快捷方式与按 tag 锁版本
- APK 本地归档带版本号：`tools/package-release.ps1` → `dist/DSH-Remote-vX.Y.Z.apk` + `dist/dsh-mobile-remote-vX.Y.Z.tgz`

## v2.5.0 / 插件 v2.4.1（2026-08-17）— 可靠性加固与体验完善

### 新增
- **手动切换连接地址**：设置 → 电脑地址点按弹出候选列表（当前打勾），探测可达后切换并重连（回家切局域网 / 出门切组网）
- **首页最近会话显示所属工作区**：小字 + 文件夹图标，与 PC 端分组同源；不属于任何工作区显示「未分组」
- **余额缓存兜底**：插件缓存余额 60s，官方 API 慢/失败时返回最近一次成功值
- **全局提示统一**：短滞留（1.6s，长错误 3s）+ 悬浮样式，不遮挡底部操作区
- 顶部在线状态点：紧贴抽屉菜单、细描边（视觉微调）
- 场景化文档：外出访问主推蒲公英（实测截图 + 下载链接），其他方案保留思路

### 修复
- **组网地址黑洞连环故障**：SSE HTTP 无超时 → 地址不通但不拒绝时永久卡 connecting、看门狗与轮换全部失效 → SSE 加 15s 超时；重配置保留旧候选地址；二维码首选局域网段
- **手动切换后界面不刷新**：switchBase 补 notifyListeners + 成功提示
- **重新配置清空旧配置**：改为新配置保存成功才覆盖，连接页提供「返回（保留原配置）」
- **SSE 僵尸连接**：半开连接立即清理（error 事件 + 写失败 dropConn）
- **余额慢链路失效**：官方接口超时 10s→15s，App 侧 15s→25s
- **引用块渲染 NaN 矩阵**：IntrinsicHeight 修复（内容重叠/无法滑动）
- Windows 防火墙「公用网络」拦截排查（FAQ 一键命令）

## v2.4.2（2026-08-17）— 连接可靠性修复

### 修复
- **SSE 静默断连卡死**：网络切换/路由器断连时 TCP 静默死亡、流不报错，App 永远显示已连接但实际离线（只能划掉重开）→ 新增心跳看门狗（识别服务器 25s `: ping`，75s 无心跳强制重建连接）+ 回前台时校验旧流活性（>45s 无心跳即重建）
- **扫码连不上（链路本地地址）**：未登录的 Tailscale/断网虚拟网卡产生 169.254.x 地址并排在地址列表首位，二维码首选这个不可达地址 → 插件排除 169.254/16 并按「局域网私有地址优先」排序；App 地址收集同步排除
- **环境诊断永远显示旧版本**：旧版只在首次打开时拉取，插件升级后仍显示旧版本号 → 每次打开实时拉取，失败明确显示「检测失败」
- 充值入口改走服务端配置（`catalog.rechargeUrl`，插件 `rechargeUrl` 为准，缺省回退官方页）

### 新增
- `trustedHosts` 配置：显式放行内网穿透中继主机（frp/SakuraFrp 场景，配合强口令）
- 单元测试 `test/api_logic_test.dart`：多地址合并/轮换/回环与链路本地排除（5 用例）

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
