# 发布前的当前状态

2026-11-04：维护者要求完成验收后继续暂停发布，先在其他窗口处理剩余 issue 和 PR。不要创建版本标签，不要勾选 publish，不发布 GitHub Release 或 npm 包。

## 已完成

- GitHub release 环境、分支范围、五项签名 Secrets 和 RELEASE_KEY_ID 已配置，并经过干净 CI 的实际签名构建验证。npm scope 尚未确定。
- PR #64、#65 已合并。main 提交为 1ff8b0388998b2a0fce6a23c40d63b3d0fc6ff46。
- [main 常规 CI](https://github.com/201222-L/dsh-mobile-remote/actions/runs/41782802522) 与 [main 签名演练](https://github.com/201222-L/dsh-mobile-remote/actions/runs/41782911398) 成功。演练 publish=false，发布作业跳过；下载产物的清单签名、哈希和 APK 正式证书已核验。
- 真机升级验收发现手动重启后的状态阻塞，修复位于 develop，随 3.2.4-alpha.3 / App build 34 验收。[修复 CI](https://github.com/201222-L/dsh-mobile-remote/actions/runs/41790623577) 已通过；细节见 [验收报告](15-upgrade-acceptance-2026-11-04.md)。

## 后续顺序

先处理 [交接清单](16-next-window-handoff-2026-11-04.md) 中的修复审阅与剩余 issue / PR，再由维护者决定发布版本、重新验收和发布时机。预览版本不是已公开发行版本。

今后需要只构建时，Actions → Prepare and publish release → Run workflow：Use workflow from=main，source_ref=要验证的分支或提交，tag 留空，publish 不勾选。详细发布约束见 [发布与配对更新](10-release-updates.md)。
