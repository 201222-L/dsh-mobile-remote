# 2026-11-04 后续窗口交接

## 维护者当前要求

先处理剩余 issue 与 PR，验收完成也不发布。不要创建版本标签、运行 publish=true、发布 GitHub Release/npm。npm scope 稍后确定。使用 Ubuntu/bash；不要使用停用的 vibehub。需要 Harness 时只启动隔离 Web，维护者桌面 Harness 正在使用。

## 工作区与分支

仓库：201222-L/dsh-mobile-remote。开发工作树 F:/DSH-Outpost/.worktrees/mobile-reliability，在 develop；Ubuntu 路径 /mnt/f/DSH-Outpost/.worktrees/mobile-reliability。先读原仓库本地 AGENT-RULES.md 并检查 git status，避免与其他窗口交叉修改。

PR #64、#65 已合并，remote main 为 1ff8b0388998b2a0fce6a23c40d63b3d0fc6ff46。develop 包含后续真机修复；不要重置或覆盖开发提交。保留 develop，不动存档 wip-autoupdate。原始工作树的本地 main 未为本次测试切换，不能把其工作目录直接当作最新远端主线。

## 本窗口已处理

main 签名 CI 和下载产物验签通过；[真机报告](15-upgrade-acceptance-2026-11-04.md) 记录安装到 alpha.3+34。新增更新器手动重启状态修复，代码提交 9ba54d680c58f88d25d4bc60a7e0bafa65e06519，[对应 CI](https://github.com/201222-L/dsh-mobile-remote/actions/runs/41790623577) 全通过。修复与验收报告已放入[草稿 PR #69](https://github.com/201222-L/dsh-mobile-remote/pull/69)，需审阅后合并 main；本窗口不代替维护者合并。

## 仍开放的 PR

- [#67](https://github.com/201222-L/dsh-mobile-remote/pull/67)：文件历史使用统一路径打开 diff 预览，目标 develop。独立审阅、复现问题和验证。
- [#66](https://github.com/201222-L/dsh-mobile-remote/pull/66)：按设置显示会话文件浏览中的隐藏条目，目前目标 main。先按开发分支约定处理合入目标，再审阅行为、路径范围和回归；本窗口未修改或合并该 PR。

## 仍开放的 issue

- [#68](https://github.com/201222-L/dsh-mobile-remote/issues/68)：文件接口路径范围、锁屏下载中断和后台续传讨论。先读最新正文与评论，再区分权限边界、系统后台限制和可实现的断点恢复。
- [#60](https://github.com/201222-L/dsh-mobile-remote/issues/60)：宿主 npm 更新及上游 npm 发行。更新流程代码与签名 CI 已实现；官方 scope 和实际 npm OIDC 发行尚未完成，不能视为全完成。
- [#58](https://github.com/201222-L/dsh-mobile-remote/issues/58)：宠物资源占包体积及通知并行链路。通知统一已有改动，资源体积仍需处理；保留桌面宠物，不恢复已取消的悬浮球产品形态。
- [#20](https://github.com/201222-L/dsh-mobile-remote/issues/20)：宿主休眠会话恢复链路。核对上游当前版本与复现证据，不把插件的错误提示改进当作宿主 readSession 已修复。

这些 PR 和 issue 在交接时均保留开放；本窗口未代替后续审阅，也没有关闭剩余 issue。
