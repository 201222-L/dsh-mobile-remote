# 发布与配对更新

## 当前能力与边界

插件默认从本仓库 GitHub Releases 检查签名更新清单；npm 是需要显式选择的可选来源，不查询无 scope 的同名包。旧发行版没有 `release-manifest.json` 时会提示使用现有 Release 下载方式。检查不会安装依赖、改写 profile 或重启宿主。

维护者的 `npm whoami` 返回 `polaris-l`。公开 registry 显示 `@polaris-l/dsh-mobile-remote@2.4.1` 的维护者也是 `polaris-l`，repository 指向本仓库；沿用它作为插件包名。配对载体采用 `@polaris-l/dsh-mobile-remote-app`，截至 2026-11-05 尚不存在，首次发布前仍需建立 Trusted Publisher。两个名称统一由 `lib/official-npm.js` 定义。此前拟用的 `@201222-l` 已废弃。同名无 scope 第三方包和其它 fork 不作为官方来源。

电脑端“连接移动端设备”和手机设置的“检查更新”提供同一流程：检查 → 用户选择下载 → 校验插件与配对 App → 用户确认插件安装 → 等待宿主退出 / 受控重启 → 新插件实际运行 → 手机下载配对 APK → Android 系统确认覆盖安装。APK 不以“发起安装”冒充“安装成功”。

桌面版始终手动退出 / 启动。Web 只有配置外部停止、启动命令时才委托该进程管理器重启；未配置时按手动流程处理。自动安装目前只支持带 `package-lock.json` 的 npm profile；pnpm profile 提供下载与人工更新，不更换包管理器，也不绕过 pnpm 的发布年龄等策略。安装前遇到运行中的 agent 会拒绝，并提示先结束任务。

## 配置

以下是现有 `mobile-remote` 行的追加配置；不用填写发行包 URL、密钥或任意脚本。

```yaml
updates:
  source: github                 # github | npm；不静默跨来源降级
  channel: stable                # stable | alpha | rc；默认不跨通道
  # npmPackage: '@polaris-l/dsh-mobile-remote'
  # profileDirectory: /绝对路径/.dsh/profiles/web
```

`profileDirectory` 留空时只检查、下载与校验，不准备安装。npm 的 registry、scope registry 和认证遵循宿主 npm 的有效配置；凭据不传给手机、也不进入更新记录。配对 App 载体必须是清单内的官方 scoped package 和精确版本，optionalDependency 缺失不能当作 App 已就绪。

载体与插件使用两个独立包名、同一个精确版本，不沿用 fork 的同名 `-app` 版本约定。检查、下载与验证都在宿主进行；切到 npm 失败不会偷偷改用 GitHub。认证失败、拒绝访问、找不到包/版本及 registry 不可达使用稳定错误码区分，原始 npm 诊断不写入手机响应或公开日志。

安装已验签的本地 tgz 时保留 profile 原有依赖键：已用 scoped 包的 profile 原位更新该键，不另加一个未被 Cordis 引用的旧无 scope 名称；同一 profile 同时声明两种身份时拒绝自动更新，要求先消除歧义。GitHub-only 清单也保留本项目既有 scoped 安装。

Web 受控部署可另加 `stopCommand`、`restartCommand` 数组和 `healthUrl`，例如由管理员提供的服务管理程序；命令使用 `shell:false`，不接受客户端提供的命令。健康地址只允许 loopback；推荐指向本实例 `/m/api/release-update/health`。桌面形态忽略这些重启命令。

## 版本与产物

每次内容变化使用新插件版本和递增 App build；不再移动已发布 tag 或替换同版本 tgz / APK。GitHub、npm 与本地归档以同一 `release-manifest.json` 配对；清单包含 commit、channel、精确文件名、大小、SHA-256、App versionName/versionCode/packageName/证书指纹和 Ed25519 签名。

App 下载流式落入私有缓存 `updates/`，校验大小 / 哈希后才交给原生端。原生再次核对实际 APK 的包名、版本、证书、大小和哈希，并要求签名与当前安装一致、versionCode 递增。更新 FileProvider 只暴露该缓存子目录。

宿主记录已见过的版本与清单 digest，遇到同版本内容变化、降级、签名或来源身份不符时拒绝。已校验下载放在当前安装实例的独立目录。安装 helper 退出宿主后才执行 npm 安装，保存 package / lock 备份和阶段日志；失败尝试恢复旧 lock 并 `npm ci`，无法恢复则明确标记需要人工恢复。中断的安装事务不会被静默当成成功。

## 配置 GitHub Actions

`check.yml` 在 PR 和 main / develop 推送时运行 Node（Ubuntu + Windows）、Flutter 和 Android 本地单测。Node 依赖使用 lockfile 与固定的宿主测试依赖，不依赖开发机现有安装。

`release.yml` 对新 `v*` tag 只构建、校验并归档产物；公开发布必须手动运行并勾选 `publish`。构建任务只有仓库读取权限，发布任务独立申请仓库写入和 npm OIDC 权限。发布顺序为验证 → 使用既有正式 Android 签名构建 → 校验 APK 实际身份 → 签名清单 → npm 载体 → npm 插件 → GitHub Release。已存在的 GitHub Release 拒绝覆盖。npm 某部分已成功时，重跑先校验已发布 tarball 的 integrity，完全一致才跳过；dist-tag 不允许回退到旧版本。

### 第一次只构建演练

GitHub 只有在默认分支存在该工作流后才提供手动运行入口，因此先审阅并合入开发 PR。`release` 环境允许 main 分支和 `v*` 标签。

1. 仓库 **Actions → Prepare and publish release → Run workflow**。
2. **Use workflow from** 选择 `main`。
3. `source_ref` 填写要验证的分支或提交，通常为 `main`；需要试构建开发线时可填 `develop`。
4. `tag` 留空，`publish` 保持未勾选。
5. 点击 **Run workflow**。完成后从该次运行页面的 **Artifacts** 下载 `signed-release-v<版本>`，其中包含正式签名 APK、插件 tgz 和签名清单。

预演不需要创建 Git tag，也不修改安装、npm 或 GitHub Release。版本名称由源码的 package.json / pubspec.yaml 推导，App build 仍须有效。

### 明确发布

验收通过后，在 main 的对应提交建立版本标签（如 `v3.2.4-alpha.2`）。推送该标签仍然只准备产物。再次手动运行时，**Use workflow from** 选择 `main`，填写已有 `tag`，勾选 `publish`；此时忽略 `source_ref`，直接构建该标签。发布前后两次校验标签对应的提交、main 归属、版本一致性，以及下载产物的签名、哈希和来源提交。最终才执行 npm / GitHub 发布步骤。

维护者在 GitHub `release` environment 设置：

- Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_PASSWORD`、`ANDROID_KEY_ALIAS`、`RELEASE_SIGNING_SEED`。
- Variables：`OFFICIAL_NPM_SCOPE`（插件包的 registry maintainer 已核对为 `polaris-l`；载体尚未建立 Trusted Publisher，因此目前留空）、`RELEASE_KEY_ID`（默认 `dsh-release-2026`，已有配置无需重配）。
- npm：由维护者建立两个官方包，并分别配置指向本仓库 `release.yml` 的 Trusted Publisher；为恢复部分发布失败允许 publish 和 dist-tag 操作。用 npm OIDC，不提交长期发布 token。

未发布验证：`node --test test/npm-update.test.mjs` 使用本地临时 registry 与测试凭据，实际执行 npm view / pack 和离线安装，覆盖 scope registry 优先级、认证、清单验签、载体配对、profile 依赖名保持及凭据不进入更新状态。这是隔离协议验证，不是公开 npm OIDC 发行成功。

签名清单复用存档更新器中的既有公开密钥；对应私钥由维护者配置。若要换钥，先完成受信公钥的兼容迁移，不能通过关掉验签解决。正式发布未提供 Android 签名时构建失败；日常 debug 构建照常。

命令入口：`npm test`、`npm run check`、`python3 tools/prepare-release.py v<版本>`；发布准备命令需要现有正式签名配置。构建物归档在 `dsh-mobile-app/dist/`，CI 的 `release-dist/` / `npm-dist/` 不进入源码提交。

## API

所有端点延续现有 Host、口令、跨站请求门禁。唯一例外是仅 loopback 可读的 `/release-update/health`，只返回插件版本。

| 端点（加 `/m/api` 前缀） | 语义 |
|---|---|
| GET `/release-update/status` | 当前阶段、配对候选、最近 100 条脱敏记录 |
| POST `/release-update/check` | 只读检查选定来源 |
| POST `/release-update/stage` | `confirmed: true` + 候选 `digest`，下载并校验配对包 |
| POST `/release-update/install` | 再次 `confirmed: true` + 原 `digest`，准备宿主退出后的安装 |
| GET `/release-update/app-info` | 只有匹配插件运行后返回 APK 身份 |
| GET `/release-update/app` | 只传送已验证的配对 APK，不接收文件路径 |

bootstrap / SSE hello 增加 `capabilities.releaseUpdates`；旧宿主上 App 隐藏入口。`app` 字段只有当前进程已加载配对插件时才出现；手机据此提示配对 App 可用。
