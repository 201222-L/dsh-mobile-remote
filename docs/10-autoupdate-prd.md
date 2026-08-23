# 10 自动更新 PRD（草案 v0.5 — 待最终放行）— dsh-mobile-remote

> 版本：草案 v0.5 · 状态：**待 Codex 最终放行** · 适用范围：App（Android）+ 电脑端插件
> 修订记录：v0.5 修 1 项 P0——digest 绑定签名载荷（payloadDigest=JCS 规范化字节哈希，替代原始字节哈希，支持合法源切换/重序列化）；并落 2 项 P1——密钥轮换改"显式支持窗口/长期双签+人工恢复路径"、HMAC 请求串规范化与 nonce 128-bit 按 token 去重。

## 1. 功能定位

- **定位**：开发者推送新版到 GitHub 后，使用者像普通软件一样"检查到 → 选择更新 → 自动安装"；电脑端插件联动（电脑上**下载校验并暂存**，用户显式完成安装与重启）。
- **服务对象**：全体使用者。不做账号体系。

## 2. 功能清单

| 编号 | 功能 | 描述 | 优先级 |
|---|---|---|---|
| F1 | 检查更新 | App 启动静默检查一次 + 设置页手动检查；默认 GitHub 源，认证电脑源可自动回退 | P0 |
| F2 | 双端版本提示 | 检查结果同时展示 App 与插件两端新版本/已最新 | P0 |
| F3 | App 更新 | 流式下载（边下边算 hash）→ 校验 → 原子改名 → 系统安装器（用户确认） | P0 |
| F4 | 插件联动更新 | App 触发电脑插件下载、校验、暂存（插件独立验签 + 受限 source），用户显式安装与重启 | P0 |
| F5 | 插件更新提醒 | 只升 App 未升插件 / 插件待安装 / 版本过低（兼容闸门）的常驻提醒 | P0 |
| F6 | 更新源切换 | GitHub 官方源（默认）/ 电脑源（updateToken 隔离通道） | P1 |
| F7 | 失败降级 | 网络/源/校验/安装失败 → 明确提示、可恢复、不打断使用 | P0 |

## 3. 发布流程（开发者侧，M1 提供发布工具）

1. push 代码 + 打 tag（如 `v3.1.0`）；
2. 发布脚本（M1 交付）：读 `pubspec.yaml` 的 `+build` 作 versionCode 并校验**严格递增**；校验三处版本一致（package.json / pubspec / git tag）；分配并持久化单调递增 **sequence**；执行兼容字段**交叉校验**（§5.1.2）；生成签名 manifest（§5.1）并连同 APK、插件 tgz 上传 GitHub Release；
3. 输出产物清单（artifactId/fileName/版本/sha256/size）供人工核对。

## 4. 用户侧主流程

```
用户打开 App（或设置页「检查更新」）
  → 获取 manifest（GitHub：Release 资产；电脑源：/update-check）
  → 验签（内置公钥集，至少一个 signatures 条目验签通过；RFC 8785 canonical）
     失败 → 更新不可信，拒绝并提示
  → sequence 规则（§5.1.3，按 {sequence, payloadDigest} 判定）
  → 兼容检查（§5.1.2）
  → 版本比较（App：artifacts.app.versionCode > 已装；插件：artifacts.plugin.versionName semver）
      两端均最新 → 「已是最新」
      有新版 → 弹窗：「发现新版本：App v3.1.0 + 电脑插件 v3.1.0  [更新全部] [稍后]」
  → 点「更新全部」——插件先行：
      A. 插件：App 把 manifest 原文交给电脑插件 → 插件内置公钥独立验签
         → 按受限 source（github / local-cache）与已验签 artifacts.plugin 取包
         → 流式下载 + hash → 暂存 → 确认 { staged: true }（未确认不进入 B）
      B. App：按已验签 artifacts.app 流式下载 → 校验 → 原子改名 → 系统安装器 → 用户确认
  → 提示：「App 已更新；电脑插件已下载就绪，请在电脑上完成安装并重启 DSH 后生效」
  → 用户按 docs/06（或让 DSH agent）完成插件安装 → 重启 DSH → 两端新版
```

### 4.1 分支流程

- **A. 只更新一端**：允许分开操作；只升 App 时插件提醒持续（§4.2）。
- **B. 稍后 / 下载中断 / 安装取消**：同一合法 manifest（同 sequence 同 payloadDigest）可**继续下载、重试、恢复**（§5.1.3 规则）。
- **C. 检查失败**：提示「检查更新失败，可稍后重试或切换更新源」。
- **D. 验签失败 / sequence 重放 / 字段非法**：拒绝一切更新动作。
- **E. 产物校验失败**：sha256 不符 → 拒绝，删临时文件，提示重试。
- **F. 签名不一致（APK）**：提示「需卸载重装」，不自动执行。
- **G. 兼容闸门**：运行时用 App 内置 `minPluginVersion` 强制；更新前发现用 manifest 字段（§5.1.2）。
- **H. 旧插件无 `/plugin-update`**：提示人工路径（docs/06）。
- **I. 安装被取消**：App 保持旧版；插件暂存保留并提示。

### 4.2 插件更新提醒触点

1. 检查弹窗两端一起报版本；
2. 首页横幅 + 设置页版本区常驻「电脑插件可升级」「插件包已下载，待安装重启」；
3. 兼容闸门硬拦截。

## 5. 接口与数据约定

### 5.1 签名 manifest（信任根）

```json
{
  "schemaVersion": 1,
  "sequence": 3,
  "channel": "stable",
  "publishedAt": "2026-08-24T00:00:00Z",
  "minPluginVersion": "3.0.0",
  "minAppVersionCode": 14,
  "minKeyringVersionCode": 15,
  "artifacts": {
    "app": {
      "artifactId": "dsh-remote-apk",
      "fileName": "DSH-Remote-v3.1.0.apk",
      "versionName": "3.1.0",
      "versionCode": 15,
      "sizeBytes": 72026882,
      "sha256": "<hex>"
    },
    "plugin": {
      "artifactId": "dsh-remote-plugin",
      "fileName": "dsh-mobile-remote-v3.1.0.tgz",
      "versionName": "3.1.0",
      "sizeBytes": 3081701,
      "sha256": "<hex>"
    }
  },
  "signatures": [
    { "keyId": "dsh-release-2026", "signature": "<base64url, Ed25519 64B>" }
  ]
}
```

- **版本字段在 artifact 内、参与签名**（`signatures` 字段除外全部字段）：升级判断**只**用 `artifacts.app.versionCode`（整数，严格递增）与 `artifacts.plugin.versionName`（semver），不从 fileName 推导。
- **签名规则**：canonical 字节 = 除 `signatures` 外的字段按 **RFC 8785（JCS）→ UTF-8**；每个签名项为 Ed25519 对同一 canonical 字节的签名（base64url、无 padding）；验签方要求**至少一个**签名项：keyId 命中本地受信公钥集且验签通过。
- **字段规则**：必填白名单；未知字段拒绝、重复键拒绝；`schemaVersion` 参与签名且恒为 1。
- **密钥轮换（双签名 + 显式支持窗口）**：换钥期间发布方用旧、新私钥**对同一 manifest 各签一份**（signatures 数组含两个 keyId）；旧客户端（只含旧公钥）验旧签，新客户端（含新旧公钥）验新/旧签。**不做"旧客户端覆盖率"推断（无账号/遥测，无法可靠测量）**——旧钥移除采用以下任一策略并由 Release 说明：① **显式支持窗口（机器可判定）**：manifest 新增独立字段 **`minKeyringVersionCode`**（可选，仅换钥发布出现），表示"自该 App versionCode 起必须使用新公钥"；客户端低于该值 → 按升级链先升到过渡版再继续；② **长期双签**：旧签名保留至产品停止发布。旧钥移除后，无法自动更新的旧客户端提供**人工恢复路径**：Release 说明附旧版 APK/插件包下载，按 docs/06 手动安装。
- **产物寻址与源解耦**：manifest 不含绝对 URL；按源解析：GitHub 按 `fileName` 匹配资产，电脑源走 `/update-file/{artifactId}`。

### 5.1.2 兼容字段方向（发布脚本交叉校验，M1）

- `minPluginVersion`：目标 App 运行时所需最低插件版本；
- `minAppVersionCode`：目标插件所需最低 App versionCode；
- `minKeyringVersionCode`（可选，仅换钥发布出现）：自该 App versionCode 起必须使用新签名公钥——**与 `minAppVersionCode` 语义独立**，不得复用；
- 发布脚本校验：新 App 的 `minPluginVersion` ≤ 新插件版本，且新插件的 `minAppVersionCode` ≤ 新 App versionCode；不满足拒绝发布。

### 5.1.3 sequence + payloadDigest 规则（防重放，支持重试/恢复/源切换）

- 两端各自持久化 **`{ sequence, payloadDigest }`**，其中：

  `payloadDigest = SHA-256( JCS(manifest 去除 signatures 字段后) 的 UTF-8 字节 )`

  即 digest **与签名载荷同源**（§5.1 canonical 字节），**不取传输原始字节**——同一合法 manifest 经电脑源解析再序列化、或 signatures 数组顺序/可用签名变化时，验签仍通过、payloadDigest 仍一致，不会被误判为"同序异内容"；首次验签通过即记录。
- 判定：
  - sequence **更小** → 拒绝（旧版本重放）；
  - sequence **相同** 且 payloadDigest **相同** → **允许**（同一 manifest：继续下载/重试/恢复中断/"稍后"后再更/**切换更新源后继续**）；
  - sequence **相同** 但 payloadDigest **不同** → 拒绝（同序号内容不一致，视为异常/攻击）；
  - sequence **更大** → 验签通过后作为新版本接受，并更新持久化的 {sequence, payloadDigest}。

### 5.2 GitHub 源（默认 canonical）

- 检查：`releases/latest` 定位最新 Release 与 manifest 资产；**信任根 = 内置公钥验签后的 manifest**（Release 资产不可变性不作安全前提）；main 固定路径仅作发现入口/镜像指针。
- 下载：按 `fileName` 匹配资产 → 流式临时文件（边下边算 hash）→ 校验 → 原子改名；不整包进内存。

### 5.3 电脑源（凭据隔离的认证局域网通道）

- **updateToken**：**高熵随机值**（24 随机字节、base64url，约 32 字符，插件生成并写入配置）；**配对写入**：随扫码/连接流程（qr-config 同通道）下发 App 并保存；**轮换**：插件设置重新生成即旧值失效，App 下次连接自动重取；**权限**：仅 `/update-*` 端点有效，访问其余 `/m/api` 一律 401（与全局 authToken 完全隔离）。
- **抗重放（canonical 请求串 + 128-bit nonce）**：请求带 `x-update-ts`（时间戳）与 `x-update-nonce`，认证值：

  `x-update-auth = HMAC-SHA256(updateToken, canonicalRequest)`，其中
  `canonicalRequest = method + "\n" + path + "\n" + canonicalQuery + "\n" + hexBodySha256 + "\n" + ts + "\n" + nonce`

  - `canonicalQuery`：query 参数按 key 升序以 `k=v` 用 `&` 连接、值经 RFC 3986 percent-encoding；无参数为空串；
  - `hexBodySha256`：请求体 SHA-256 的 hex；无请求体时为 SHA-256(空串)（为将来 POST 预留）；
  - `nonce`：**至少 128-bit 随机**（16 字节，hex 或 base64url）；服务端按 **token 分区**去重缓存，±60s 时间窗，重复 nonce 拒绝。
- 端点：`GET /m/api/update-check`（返回 manifest）；`GET /m/api/update-file/{artifactId}`（按 manifest 校验 size/sha256）。
- 二期：插件当下载代理。

### 5.4 插件更新（F4，只暂存不自覆盖）

- `POST /m/api/plugin-update { manifest, source }`：`source ∈ { "github", "local-cache" }`（**枚举受限**，不接受任意地址）；
- 插件**以自身内置公钥独立验签 manifest** → 仅使用已验签 `artifacts.plugin`（artifactId/fileName/versionName/sha256）→ 按 source 从**预设来源**取包（github：Release 资产按 fileName；local-cache：插件更新目录按 artifactId）→ 流式下载 + hash → 校验 → 暂存 + 备份 → `{ staged: true }`；
- 安装与重启不在本端点内（docs/06 或 DSH agent 显式执行）；不运行时自覆盖、不自重启。

## 6. 安全与边界

- **信任链**：内置公钥验签 manifest（RFC 8785）→ manifest 内 sha256 校验产物 → Android 系统签名（APK）；sequence+payloadDigest 防重放（§5.1.3）。
- **凭据**：公网仅 HTTPS；电脑源 updateToken 隔离（高熵、抗重放、权限最小化、可轮换）。
- **无静默安装**：系统安装器 + 用户确认；M1 前置：`REQUEST_INSTALL_PACKAGES`、未知来源检查、FileProvider/content URI、安装结果回调。
- **不做推送通道**；不后台轮询。
- **防回滚**：App 升级判断 = target.versionCode > installed；插件 semver 比较。
- **签名约定**：官方 APK 同 key 覆盖安装；换 key 发版注明"卸载重装"。

## 7. 明确不做（本范围外）

- 静默安装 / 强制升级 / 后台轮询推送；
- 插件运行时自覆盖或自重启；
- iOS；应用商店上架；多用户账号体系。

## 8. 里程碑

- **M1（MVP）**：签名 manifest（JCS + 双签名能力 + artifact 版本字段 + sequence/payloadDigest）+ 发布脚本（版本校验/sequence/交叉校验/生成 manifest）+ GitHub 源检查 + App 流式下载/校验/安装 + 双端版本弹窗 + 插件提醒与兼容闸门 + Android 安装前置；
- **M2**：插件暂存（独立验签 + 受限 source）+ 电脑源（updateToken 隔离通道 + `/update-file/{artifactId}`）；
- **M3（二期可选）**：镜像/加速源、插件下载代理、自动检查频率设置、channel（beta）。

## 9. 测试与验收要点

- 单测：JCS canonical 已知向量；验签（合法/篡改/重复键/未知字段/缺必填/keyId 不识别/**双签名新旧各自可验**）；**payloadDigest：跨源/重序列化/signatures 顺序变化后一致、同序异 payload 拒绝**；sequence 四规则；versionCode/semver 比较；sha256 失败拒绝；发布脚本对版本不一致/sequence 非递增/交叉校验失败的报错；
- 通道：updateToken 访问 `/m/api` 401；**canonicalRequest 拼接（含 query/body hash）正确性**；HMAC 时间窗外/重复 nonce 拒绝、**nonce 按 token 分区去重**；轮换后旧 token 失效；
- 真机：GitHub 全链路更新；**下载中断→同 manifest 恢复**；**稍后→再检查不误判重放**；签名失败拒装；取消安装；插件暂存成功但 APK 安装失败 → 暂存保留；旧插件无端点 → 人工路径；断网降级；
- 双端联动：插件暂存 → 重启后两端一致；兼容闸门（双向）拦截；
- 回滚：插件暂存失败清理、备份可回退。

## 10. 已裁定结论（不再开放）

1. 信任根 = 内置公钥验签的签名 manifest（JCS/RFC 8785；双签名轮换）；
2. 升级判断 = artifacts 内嵌 versionCode/semver 字段，不经 fileName 推导；
3. 防重放 = sequence + payloadDigest 四规则（digest 绑定 JCS 签名载荷，跨源/重序列化一致）；防回滚 = versionCode 严格递增；
4. 插件更新 = 插件独立验签 + 受限 source + 暂存 + 外部安装；
5. 电脑源 = updateToken 高熵隔离通道（HMAC 抗重放），不复用全局 authToken；
6. 更新源默认 GitHub；认证电脑源作回退。
