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
- 后续 USB 真机验收使用独立 QA 包，下载断点恢复与最终哈希、原生宠物冷启动/16 动作及通知职责通过，正式 App 未覆盖；详见 [真机可靠性报告](18-device-reliability-acceptance-2026-11-04.md)。不限速的 USB 测试中，32 MiB 点选至文件写满约 1.49 秒，不能代表 Wi-Fi。
- 最新事实、完整验证结果和各 issue 的未完成部分见 [剩余工作复核](17-remaining-work-review-2026-11-04.md)。PR #69 随 develop 扩展为这些开发改动与验收记录的草稿。

## issue 后续状态

#58 已回复贡献者并以 completed 关闭；详见 [本轮 issue 后续记录](19-issue-followup-2026-11-04.md)。#20 按维护者最新要求暂不处理。

## 仍未完成

DSH 最新 prerelease 为 `0.2.2-rc.1`；四项 peer prerelease 范围此前实际拒绝 0.2.x RC，已修复。47 项代际兼容测试、针对上游 API 形状的源码核对及 npm `--dry-run` 真实解析 20 项依赖通过。全量 Node 282 项、Python 8 项、npm run check 和 Flutter 3.47.0 analyze 均通过。Node 下限随 DSH 宿主提升至 24.9；本机为 24.15。`readSession()` seeded 旧日志缺陷仍在，#20 按维护者要求不处理。上游 `master` 为 `fcc0ad4`，即该 RC 发布合并，没有发现更新的公开发行版。详见 [DSH 0.2.2 兼容审查](20-dsh-022-compatibility-2026-11-05.md)。

本次检查发现的新 PR 为 #70（常驻通知静音 / 通知权限设置入口），仍开放、目标 main，现有 CI 全绿。改动不触及插件依赖的 DSH API；本轮只审阅，没有合并或改目标。

- [#68](https://github.com/201222-L/dsh-mobile-remote/issues/68)：续传实现已补；全路径信任边界有文档，未把工作区列表伪装成授权。独立 QA 包的进程退出后恢复、系统下载目录保存与哈希已通过；息屏请求后观察约 65 秒，未证明进入全机 Asleep/Doze。长时间省电策略、Wi-Fi 和不同 ROM 仍需覆盖；后续新增下载专用 dataSync 前台服务与通知暂停/系统超时收尾，自动化通过；补测时 ADB 无设备，新服务真机待连接后验证，不能沿用前次报告算作已通过。

- [#20](https://github.com/201222-L/dsh-mobile-remote/issues/20)：0.2.1-rc.5 和 0.2.2-alpha.3 的公开包仍有老 seeded 日志构造路径问题；最新 alpha 已用真实构造器和合成日志独立复现。插件错误分类/降级/恢复 17 项回归通过，兼容分支继续保留，等待上游及原受影响日志复核。
- [#60](https://github.com/201222-L/dsh-mobile-remote/issues/60)：维护者确认 npm `whoami` 为 `polaris-l`；公开 registry 显示 `@polaris-l/dsh-mobile-remote@2.4.1` 的 maintainer 与仓库地址匹配。拟用载体为 `@polaris-l/dsh-mobile-remote-app`，尚未创建。scoped 安装更新修复及隔离 registry 验证已补；载体 Trusted Publisher/OIDC 未设置，继续保持 GitHub 默认来源，不发布。

除已关闭的 #58 外，其余 issue 保持开放；自动化测试不能替代手机锁屏验收，之前模拟的 GitHub 发行响应不能算公开 CDN 或 npm OIDC 已验证。先前代码审阅未启动 Harness 或改写手机；后续 USB 验收只启动全新隔离 Web，安装并清理独立 QA/探针包，未触碰桌面 Harness、正式 App 数据或私有会话日志。
