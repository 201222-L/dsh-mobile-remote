# 11 M2 设计草案 v0.3 — 插件联动更新 + 电脑源（dsh-mobile-remote）

> 状态：**待 Codex 最终设计放行** · 基线：M1（commit `ba7c493`，Codex 最终放行，未推送）
> 修订记录：v0.3 采纳 Codex 评审——双源对照升级为 **sequence+payloadDigest 双一致判定**（同 sequence 不同 digest = 账本冲突，拒绝更新）；helper 执行时序裁定（独立进程 + 等待 DSH PID 退出；宿主内 agent 不直接替换文件）；替换事务明细（同卷交换/journal/崩溃恢复/解压临时目录）；`update-file` 产物缺失的回退规则（仅同 sequence+同 digest 才可跨源取）。

## 1. M2 目标与主流程

```
用户点「更新全部」：
  A. 插件先行：App 把已验签 manifest + source + declaredAppVersionCode 交给电脑插件
     → 插件以自身内置公钥【独立验签】（不信调用方任何 URL/hash）
     → 按受限 source 取包（github：PC 直连 GitHub 下载；local-cache：插件更新目录）
     → 流式下载 + sha256/size 校验 → 暂存到更新目录 + 备份现状 → { staged: true, 生效说明 }
     未确认 staged 前不进入 B
  B. App 下载安装（M1 链路）
  完成 → 提示：「插件包已下载并校验，请退出 DSH → 运行 apply 命令 → 重新启动 DSH」
```

**生效机制（v0.2/0.3 裁定）**：**外部 helper/显式命令**，不做任何运行时/启动早期自应用：
- helper（随 npm 包安装，见 §5.2）在 **DSH 已退出**状态下运行：校验 staged 包（重新验签 manifest、重验 tgz sha256，见 §5.2 事务）→ **原子替换**插件目录 → 保留备份（可回滚）；
- 文案承诺「**退出 DSH → 执行 helper → 重新启动**」，不承诺"重启一次自动生效"；
- **DSH agent 代为执行的合法方式（v0.3 裁定）**：agent 仅在**用户确认后** spawn **独立 helper 进程**并传入当前 DSH PID；helper **等待该 PID 退出**后，才执行校验/替换/回滚——**仍运行在宿主内的 agent 不得直接替换插件文件**；用户也可退出 DSH 后从终端显式执行 helper。

## 2. 电脑源（F6）设计

### 2.1 凭据：updateToken（与全局 authToken 完全隔离）

- 生成：插件首次启动生成 24 随机字节 base64url，写入 `~/.dsh/mobile-remote/update-token.json`（0600）；
- 下发：**仅经扫码/配对通道**（qr-config 增加 `updateToken` 字段）；**轮换后不自动重取**——轮换命令执行后，App 提示「请重新扫码配对」获取新 token（qr-config 为 loopback-only，不为"自动重取"开任何新通道）；
- 权限：仅更新端点；其余 `/m/api` 一律 401。

### 2.2 请求签名（抗重放）

与 PRD §5.3 一致：`x-update-ts`/`x-update-nonce`(≥128-bit)/`x-update-auth = HMAC-SHA256(updateToken, canonicalRequest)`；canonicalRequest = `method\npath\ncanonicalQuery\nhexBodySha256\nts\nnonce`；±60s；nonce 按 token 分区去重缓存。

### 2.3 认证分流（实现约束）

- 更新端点在**现有全局 authToken 中间件之前**分流路由：`/update-*` 与 `/plugin-update` 由 updateToken/HMAC **单独认证**，绝不过全局校验；
- 全局中间件对无 authToken 的更新端点请求直接放行到更新认证（否则 401 语义错乱）。

### 2.4 端点

| 端点 | 用途 |
|---|---|
| `GET /m/api/update-check` | 返回扫描 `~/.dsh/mobile-remote/updates/` 所得 manifest（无 → 404） |
| `GET /m/api/update-file/{artifactId}` | **仅允许当前已验签 manifest 明确声明的两个 artifactId**（`dsh-remote-apk` / `dsh-remote-plugin`）；**禁止把路径参数直接映射为文件路径**（白名单查表 → 更新目录内固定文件名）；校验 size；未知 id → 404 |
| `POST /m/api/plugin-update` | 入参 `{ manifest, source, declaredAppVersionCode }`：插件独立验签 → 受限 source → 校验 → 暂存 → `{ staged: true }` |

### 2.5 电脑源自动模式（v0.3 裁定：双源对照 + 双一致判定）

- **自动模式 = 电脑源与 GitHub 源都查询**，均须验签；**判定必须同时纳入 App 已持久化的 `{sequence, payloadDigest}`**（非阻塞约束，与 M1 四规则对齐）：
  - 两源均**低于本地已记录 sequence** → 按 M1 规则拒绝（重放）；
  - 任一源与本地**同 sequence** → 该源的 payloadDigest 必须与本地一致才允许继续（sameAllowed），否则同一内容冲突拒绝；
  - 双侧都返回合法 manifest 时按 **sequence + payloadDigest 双一致判定**（与 M1 四规则对齐）：
  - sequence **不同** → 取更高者的 manifest 作为更新目标；
  - sequence **相同且 payloadDigest 相同** → 同一 manifest，任一源可提供产物；产物下载：目标源优先，缺失时另一源**仅在返回同 sequence + 同 payloadDigest 的 manifest 时**才可供应；
  - sequence **相同但 payloadDigest 不同** → **发布账本冲突**：拒绝更新并报「两个源返回同 sequence 不同内容」（**绝不优先任一源**，防止被篡改的电脑缓存混入）;
- 电脑源 manifest 合法但**旧于** GitHub（或旧于本地记录）→ 以 GitHub 为准，陈旧缓存不可能遮蔽新版；
- **「仅电脑源」**保留为用户**显式选项**（显示"可能不是最新，GitHub 可查"提示）；「仅 GitHub」「自定义」同上（M1 已有）；
- 选项：自动（电脑优先）/ 仅电脑 / 仅 GitHub / 自定义——设置页四选一。

### 2.6 update-file 产物缺失（v0.3 裁定）

- 目标 manifest 来自电脑源、但 `update-file` 缺某产物（如 APK 在电脑更新目录不存在）时：
  - **仅当 GitHub 返回同 sequence + 同 payloadDigest 的 manifest** → 允许按 GitHub 下载该产物；
  - 否则返回明确错误「电脑缓存不完整（缺 artifactId）」——**禁止混用不同 manifest 的产物**（不同 digest 的 APK 与 manifest 组合 = 破坏信任链）。

## 3. 插件端（F4）实现要点（lib）

### 3.1 共享加密模块（v0.2 P0 裁定）

- 新建 **`lib/update-crypto.js`**（随 npm 包发布，发布白名单必须包含）：JCS 规范化、Ed25519 验签/签名、manifest 验签（至少一个 keyId 命中且通过）；
- **发布工具与插件共同 import 它**；`lib` **不得依赖 `tools/`**（npm 白名单不含 tools/，安装后找不到）——tools 只保留 CLI/发布编排层；
- `tools/publish-update.mjs` 重构：加密/验签部分改从 `lib/update-crypto.js` 导入（行为回归以现有 20/20 单测保证，测试改为同时覆盖两种消费路径）。

### 3.2 产品校验与暂存

- 产物 sha256 + sizeBytes 双校验；失败清理；暂存目录 `~/.dsh/mobile-remote/updates/staged/<versionName>/` + 备份 `backup/<versionName>/` + `staged.json`；
- 幂等：同 manifestDigest 重复 `/plugin-update` → 直接 `{ staged: true }`；
- 受限 source：非 `github`/`local-cache` → 400；调用方 URL/hash 不作为信任输入。

### 3.3 minAppVersionCode（v0.2 裁定）

- 插件端要求请求携带 `declaredAppVersionCode`（整数）；低于 manifest 要求 → **409**；
- **明确文档**：这是防正常客户端误操作，**不是安全信任边界**（客户端可伪造版本号）；真正强制在 App 端自查硬拦截。

### 3.4 能力字段（配合老 App）

- 插件 bootstrap 增加 `capabilities: ["plugin-update-endpoint"]`；App 以**能力字段**（而非版本号猜测）判断是否可走插件联动；无该能力 → 「仅提示」路径（docs/06 人工）。

## 4. App 端实现要点

- 「更新全部」顺序：先 `plugin-update`（确认 staged）→ 再 App 下载安装；
- `plugin-update` **前自查硬拦截**：当前 versionCode ≥ manifest.minAppVersionCode，否则不发插件更新并提示（文案明确指向人工先补 App 升级链）；
- 请求携带 `declaredAppVersionCode`（自身真实版本）；
- 能力字段驱动：`capabilities` 不含 `plugin-update-endpoint` → 「仅提示」；
- 电脑源自动模式：按 §2.5 双源对照；产物下载按选定源。

## 5. 发布与分发

### 5.1 共享模块随包

- `package.json` `files` 白名单增补：`lib/update-crypto.js`、`lib/apply-update.js`（helper）；
- `export-pubkey` 同时复写插件 `lib/update-crypto.js` 的受信公钥表 + App `lib/update/trusted_keys.dart`。

### 5.2 helper（生效执行者）

- 随 npm 包安装，注册 `bin`（如 `dsh-remote-apply-update`）；DSH agent 代执行时 spawn 独立 helper 并传入 DSH PID（§1 时序裁定）；
- **替换事务（v0.3 裁定，可恢复）**：
  1. 前置校验：重新验签 manifest（与暂存时同一内置公钥）、重验 tgz sha256、确认 staged.json 与包一致；
  2. 解压 tgz 到**更新目录内的临时目录**（不直接写安装路径）；
  3. **同卷目录交换**：`段rename` 安装目录 → `backup/<version>.prev`；临时目录 → 安装目录；若任何一步失败 → journal 记录并自动回滚（恢复备份）；
  4. **journal + 崩溃恢复**：事务开始前写 `journal.json`（阶段/路径/指纹），下次 helper 启动时检测未完成事务 → 按状态回滚或续做；
  5. 成功后清理 journal 与临时目录、输出「已更新，可启动 DSH」。

## 6. 测试与验收（M2）

- 纯逻辑单测：update-crypto（篡改/缺字段/未知 keyId/双签名新旧可验，与 App/工具三方一致）、token HMAC（时间外/重复 nonce/错 token）、受限 source、staged 幂等、minAppVersionCode（App 拦截 + 插件 409）、capability 分支；
- 端点集成：认证分流（更新端点无 authToken 不被全局拦）、/update-file 未知 artifactId 404、无 updateToken 401、更新目录缺 manifest 404；
- 真机演练：① 自动模式双源对照——电脑<GitHub 以 GitHub 为准；电脑更高走局域网；**同 sequence 异 digest → 弹「账本冲突」拒绝**；② 插件暂存 → 退出 DSH → helper 替换 → 重启 → 插件版本更新 + App 显示一致；③ 回滚（helper 失败还原备份 / journal 中断恢复）；④ 老 App（无 capability）→ 仅提示；⑤ updateToken 轮换 → App 提示重新扫码；⑥ 电脑缓存缺产物 → 仅同 manifest（digest 一致）时跨源取，否则「电脑缓存不完整」；⑦ agent 代执行：确认 → spawn helper 传 PID → 等待退出后替换（宿主内 agent 不直接改文件）。

## 7. 已裁定结论（v0.3，不再开放）

1. 共享加密模块 `lib/update-crypto.js` 随包发布；lib 不依赖 tools；
2. 插件生效 = **外部 helper/显式命令 + 用户退出/重启 DSH**；不做任何运行时/启动早期自应用；agent 代为执行 = 用户确认后 spawn 独立 helper + 传入 DSH PID + **等待 PID 退出**后校验/替换/回滚；宿主内 agent 不直接替换插件文件；
3. 电脑源自动模式 = **双源对照 + sequence/payloadDigest 双一致判定**：同 sequence 异 digest = **账本冲突拒绝更新**；仅同 sequence 同 digest 允许跨源取产物；「仅电脑源」为用户显式选项；
4. updateToken 轮换 = 提示**重新扫码配对**（无自动重取；qr-config loopback-only 不开新通道）；
5. minAppVersionCode = App 硬拦截 + 插件端 `declaredAppVersionCode` 校验（409；非安全信任边界，文档声明）；
6. 老/新插件兼容用 **capability 字段**判断，不猜版本号；
7. 更新端点先于全局 authToken 分流，updateToken/HMAC 单独认证；`/update-file/{artifactId}` 白名单化（禁止路径参数直接映射文件）；
8. 替换 = **可恢复事务**（同卷 rename 交换 + journal + 崩溃恢复；替换前重验签 manifest/重验 tgz/解压临时目录）；产物缺失仅允许同 sequence+同 digest 跨源，否则明确报「电脑缓存不完整」。
