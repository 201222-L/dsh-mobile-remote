# 2026-11-04 后续窗口交接

## 维护者要求

先处理剩余问题，暂不发布。不要创建标签、运行 publish=true、发布 GitHub Release/npm；公开版本继续为 v3.2.3，官方 npm scope 稍后决定。使用 Ubuntu/bash，不使用停用的 vibehub。需要 Harness 时只启动隔离 Web，不停止、升级或重启维护者桌面 Harness。

## 工作区

仓库：201222-L/dsh-mobile-remote。开发工作树 F:/DSH-Outpost/.worktrees/mobile-reliability，在 develop；Ubuntu 路径 /mnt/f/DSH-Outpost/.worktrees/mobile-reliability。先读原仓库本地 AGENT-RULES.md、检查 git status 并核查 GitHub 最新状态，保留其他窗口修改和既有开发提交，不重置 develop，不动存档 wip-autoupdate。

main 是发布线，remote main 仍为 1ff8b0388998b2a0fce6a23c40d63b3d0fc6ff46。原始工作树的本地 main 未同步到该远端状态，不能直接当成最新主线使用。后续开发只提交、推送 develop；#69 保持草稿待审阅，不合并 main。

## 已核实和集成

- PR #64、#65 已合并；release 环境、五项签名 Secrets 与 RELEASE_KEY_ID 已配置，签名 CI、真实下载产物验签和真机升级通过。无需重新配置。
- 更新器手动重启状态修复提交 9ba54d6 已在 develop；手机已从 alpha.1+32 覆盖升级到正式签名 alpha.3+34。详细范围、原偏好恢复与收尾见 [真机报告](15-upgrade-acceptance-2026-11-04.md)。原产物在原仓库 dsh-mobile-app/dist/，不得替换同版本产物或提交构建输出。
- PR #67 已审阅、36 项文件历史定向测试通过，以 2f23333 合入 develop。
- PR #66 已先改目标为 develop，保留设置页两组冲突测试；22 项宿主、31 项 App 定向测试通过，以 ceb5b76 合入 develop。#66/#67 集成提交的 Windows / Ubuntu / Flutter CI 均通过。
- 新增文件私有断点、恢复/暂停/删除入口、If-Range 与完整长度校验；宠物资源统一到 Flutter assets，合计约 8.3 MiB → 6.2 MiB。当前仍保留桌面宠物产品和通知职责边界。
- 最新事实、完整验证结果和各 issue 的未完成部分见 [剩余工作复核](17-remaining-work-review-2026-11-04.md)。PR #69 随 develop 扩展为这些开发改动与验收记录的草稿。

## 仍未完成

- [#68](https://github.com/201222-L/dsh-mobile-remote/issues/68)：续传实现已补；全路径信任边界有文档，未把工作区列表伪装成授权。尚需真机长时间锁屏、进程回收与恢复保存测试；未新增 dataSync 前台服务，不承诺锁屏连续下载。
- [#58](https://github.com/201222-L/dsh-mobile-remote/issues/58)：资源去重及通知职责代码已处理；尚需当前构建上的原生宠物冷恢复、完整互动、减弱动效和后台通知组合真机复核。旧内部 FloatingBubbleService 名称是兼容保留，不能恢复已取消的圆形悬浮球。
- [#20](https://github.com/201222-L/dsh-mobile-remote/issues/20)：0.2.1-rc.5 和 0.2.2-alpha.3 的公开包仍有老 seeded 日志构造路径问题；最新 alpha 已用真实构造器和合成日志独立复现。插件错误分类/降级/恢复 17 项回归通过，兼容分支继续保留，等待上游及原受影响日志复核。
- [#60](https://github.com/201222-L/dsh-mobile-remote/issues/60)：官方 npm scope/包名未决定，实际 npm OIDC 发行未验证。继续保持 GitHub 默认来源，不查询第三方同名包，不发布。

以上 issue 保持开放；自动化测试不能替代手机锁屏验收，之前模拟的 GitHub 发行响应不能算公开 CDN 或 npm OIDC 已验证。本轮没有启动 Harness、改写手机或读取私有会话日志。
