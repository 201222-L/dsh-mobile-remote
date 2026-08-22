# 04 安全设计文档 — dsh-mobile-remote

> 版本：v3.0.0 · 状态：已实现 · 配套：02-architecture.md、03-api.md、09-compatibility.md

## 1. 威胁模型

### 1.1 资产

| 资产 | 价值 |
|---|---|
| agent 控制权 | 极高：agent 可执行 bash/pwsh（本机全权限 ≥ 远程代码执行） |
| 会话内容 | 高：对话、工具输出、工作区文件内容 |
| 访问口令 | 高：等于 agent 控制权（App 持有即已认证） |

### 1.2 攻击面与威胁

| 威胁 | 路径 | 前置条件 | 等级 |
|---|---|---|---|
| T1 局域网内任意设备驱动 agent | 系统监听 0.0.0.0 后，同网段设备直接访问 `/m/api/*` | 口令未启用 | **高** |
| T2 公网暴露 | 路由器 3080 端口映射/穿透到公网 | 用户违反约束 | **极高**（禁止项） |
| T3 口令爆破 | 反复携带口令访问 API | 口令启用 | 低（v2.6 起登录限流：10 次/60s → 429 + Retry-After） |
| T5 中间人窃听 | WiFi 被监听，明文 HTTP | 无 TLS | 中（见 §3） |
| T6 DNS 重绑定 | 攻击者域名解析到 127.0.0.1 后经浏览器访问 | 无 TLS | 低（Host 校验阻断，见 §5） |

### 1.3 攻击面缩减原则
1. **默认回环**：未配置 0.0.0.0 时，插件随 webserver 只监听 127.0.0.1，移动 API 物理不可达。
2. **通路分级**：可信 WiFi（家用）→ 允许 0.0.0.0 + 建议口令；外出 → 虚拟组网（蒲公英实测推荐 / Tailscale 思路，WireGuard 加密 + 设备认证）；公网直连 → 禁止。
3. **口令即闸门**：启用口令后，全部移动 API（含 SSE）在建立连接时校验；任何绕过路径返回 401。
## 2. 身份鉴权方案

### 2.1 访问口令（推荐启用）

- 配置项 `authToken`（`cordis.patch.yml` 注入），**默认空 = 关闭**。
- App 每次请求携带 `X-Mobile-Token: <token>` 头；服务端常量时间比较（`crypto.timingSafeEqual`）。
- 失败统一 `401 auth-required`，避免枚举。
- 口令长度要求（文档约束）：≥ 16 字符，用 `crypto.randomBytes(24).toString('base64url')` 生成。
- 口令比较为**常量时间**（sha256 定长化 + `timingSafeEqual`，v2.6 起消除长度侧信道）。
- **登录限流（v2.6）**：错误口令按来源 IP 计数，窗口内 ≥10 次 → `429 rate-limited` + `Retry-After`；认证成功重置计数；仅口令启用时生效（可配 `rateLimit.maxFailures/windowMs/blockMs`）。frp 等中继场景所有外部请求同源（中继 IP），阈值对单用户足够宽裕。
- 每台电脑使用**不同口令**；二维码含口令，泄露后立即更换（改配置 + 重启，旧码作废）。
### 2.2 Cookie 通道（兼容保留）

- 名称 `dsh_mobile_token`；`HttpOnly`、`SameSite=Lax`、`Path=/m`。v2.1 起无登录入口（网页版已移除），仅供旧客户端兼容，与请求头等价。
### 2.3 认证中间件实现要求
- 所有受保护端点统一走一个 `authorized(req)` 前置校验；禁止散落判断。
- 校验失败：`401` + 统一错误体；SSE 端点同样在 HTTP 头阶段拒绝（不建立流）。
## 3. 传输安全

| 通路 | 传输安全 | 说明 |
|---|---|---|
| 127.0.0.1 回环 | 本机可信 | 默认 |
| 局域网（可信 WiFi） | 无 TLS，明文 | 家用 WiFi 信任模型；口令启用时明文风险可接受 |
| 虚拟组网（蒲公英/Tailscale） | **WireGuard 端到端加密 + 设备身份** | 外出唯一通路（蒲公英国内可用，实测推荐） |
| HTTPS 反代（可选，v2.6 文档化） | TLS（受信任 CA / 手机安装内网 CA 根证书） | 不信任 WiFi / 公网反代场景；部署见 06-install-run §6b |
| 公网裸 HTTP | **禁止** | 运维约束：不映射端口、不做 NAT 穿透到 3080 |

明文路径下口令可能被同网段监听者截获——这是**明确的残余风险**，缓解手段：仅可信 WiFi 使用、口令启用、定期更换。

### 3b. LAN 桥（v3.0.0：桌面版局域网直连的官方通道）
> 背景：DSH Desktop（0.1.1-rc.2 起）强制 webserver 只听 `127.0.0.1`（`dsh-plugin-desktop` 的 DesktopWebServer 构造器对非回环 host 直接 throw，用户 patch 无法覆盖），手机无法直连桌面版。插件在 DSH 进程内自建第二个 HTTP 监听（`lanBridge`，默认 `0.0.0.0:3080`），把 `/m/api*` 流式转发到回环 webserver（SSE 透传）。

**这是新增攻击面，边界在代码中强制（`lib/index.js`「LAN 桥」段）：**
1. **只转发移动 API 面**：`pathname.startsWith(/m/api)` 之外一律 404——桌面 `/api` RPC 网关、`/m/api/qr-config`（含口令）、`/m/qr.png`（仅本机语义）、一切其他 `/m/*` 面均不转发；Host 头重写为 `127.0.0.1:<webServer.port>` 使下游 hostAllowed 自然放行（真实鉴权仍由口令把关）。
2. **口令强制**：未配置 `authToken`、或口令短于 16 字符 → **拒绝启动桥**（仅警告不断言；schema 不设 min 以免破坏既有用户）并记日志。
3. **资源防护**：`maxConnections=128`、headersTimeout 15s、requestTimeout 60s、upstream 15s 超时、在网连接随插件卸载销毁。
4. **暴露条件**：桥默认关闭；开启即等于「0.0.0.0 移动 API 可达」——前置条件：可信 WiFi + ≥16 字符强口令（同 §2.1）。`/m/api/diagnostics` 的 `runtime.lanBridge.listening` 可确认监听状态（绑定失败时 QR/地址自动回退，不会指向死端口）。
5. **与 §3 表格关系**：桥上的流量走「局域网（可信 WiFi）明文」档位，残余风险与缓解同 §3 末。

## 4. 前端注入防护（XSS）
- App 为 Flutter 原生渲染（无 HTML 注入面）；消息内链接仅 http/https 可点击（v2.6 起 scheme 白名单，`file:`/`intent:`/`tel:` 等一律渲染为纯文本）。
- 插件 API 返回的文本为纯 JSON（不含 HTML）；桌面客户端模块（设置页二维码）仅渲染服务端返回的地址/口令文本。
## 5. Host 校验

- 移动 API 处理前校验 `Host` 头：必须匹配回环地址、本机任一面 internal IPv4（含 Tailscale），不匹配 → 403（阻断 DNS 重绑定，与 dsh /api 信任围栏同思路）。
- 名单在插件激活时以 `os.networkInterfaces()` 快照（过滤虚拟网卡：VMnet/vEthernet/代理虚拟网段）。
- `trustedHosts`（v2.4.2+）：隧道/中继类方案（frp/SakuraFrp 托管）下请求 Host 是中继地址，需在此显式放行（配合强口令）；纯虚拟组网/局域网无需配置。
## 6. 数据安全

- 插件**持久化仅限最小移动端状态**（`~/.dsh/mobile-remote/`：通知已读 id、会话最近活跃时间），不含会话内容；口令只存在于 profile 配置。
- 会话内容沿用 dsh 现有策略存储；插件仅在请求处理期间持有内存副本。
- **二维码数据端点 `/m/api/qr-config` 仅允许 loopback**（TCP socket 来源校验，无法伪造）—— 桌面设置页读取后展示二维码；二维码含地址+口令，请勿截屏转发。
- **问询/审批应答（`/m/api/respond`）不绕过内核安全**：插件只是把客户端 payload 转交 `apiProxy.respond`，答案内容（选项合法性、custom/selected 互斥、审批 outcome 枚举）全部由内核 schema 校验；rpcId 必须命中内核 pending 表（先到先得，不可伪造待答）。取消操作同样走内核 `ASK_CANCELLED` 语义。
- **第三方推送通道脱敏（v2.6）**：Server酱/ntfy/Bark/generic 等推送默认只收到「事件类型 + 会话短码」（`pushContent: minimal`），会话标题/错误详情等核心内容默认不出本机；仅显式配置 `pushContent: standard` 后外发——第三方服务不可信。
## 7. 安全测试要点（并入 05-test-cases.md）
1. 口令启用后：未认证访问 bootstrap/send/events/history 返回 401；错误口令 401。
2. 口令关闭时：以上端点返回 200。
3. Host 校验：伪造 Host 头 → 403。
4. `/m/api/qr-config`：非 loopback 来源 → 403；loopback → 200。
5. 系统监听 0.0.0.0 后，从另一台设备验证：同网段可访问（设计内行为）；确认公网端口未开放。
6. LAN 桥：未配置口令/短于 16 字符 → `diagnostics.runtime.lanBridge.listening=false` 且日志有拒绝提示；配置正确 → listening=true，经桥访问 bootstrap 200、无口令 401、`/m/api/qr-config` 与 `/api/*` 一律 404（模拟环境若无法真机，用另一台同网设备 curl 验证）。
## 8. 运维约束（与 06-install-run.md 联动）
- 启用 0.0.0.0 前确认网络为可信 WiFi；离开可信网络前确认服务未在公网可达。
- 建议（非强制）在 profile 配置中启用口令；口令变更 = 改配置 + 重启 dsh。
- 虚拟组网为外出标准姿势（蒲公英国内实测推荐；Tailscale 国内控制面不可达）；纯组网方案插件侧无需额外配置，隧道/中继类需 `trustedHosts` 放行 + 强口令。
- `authToken` 必须启用（v2.6 起启动日志与桌面设置页对「认证未启用」显式警示）；不信任的 WiFi（酒店/咖啡馆）下优先 HTTPS 反代（06-install-run §6b）。
