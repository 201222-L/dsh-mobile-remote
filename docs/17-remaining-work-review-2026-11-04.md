# 2026-11-04 剩余问题复核

## 分支与发布边界

起点为 `develop` 的 `e4aa123`，工作目录无未提交改动。GitHub 同名分支也已到该提交，本地缓存的 origin/develop 尚落后一个文档提交。后续保留既有提交，只向 develop 集成；原工作树 main 与存档 wip-autoupdate 未切换或改写。

公开版本继续为 v3.2.3。本轮不创建标签、不调用 publish=true、不发布 GitHub Release/npm；不重新配置已验证的 release 环境、五项签名 Secrets 或 RELEASE_KEY_ID。既有 alpha.3+34 正式签名验收产物未替换，范围仍以 [真机报告](15-upgrade-acceptance-2026-11-04.md) 为准。未启动或更改桌面 Harness，也未启动隔离 Web。

## PR

- [#67](https://github.com/201222-L/dsh-mobile-remote/pull/67)：审阅路径归一化、失效路径和分页时序后，在当前开发线运行 36 项文件历史测试通过。以 `2f23333` 合入 develop，保持 `/git/preview` 只接受仓库相对路径。
- [#66](https://github.com/201222-L/dsh-mobile-remote/pull/66)：先改目标为 develop，再集成。设置页测试发生内容冲突，保留原有 Git 标签偏好测试及新隐藏文件测试；22 项宿主测试、31 项 App 定向测试通过。以 `ceb5b76` 合入 develop。两组集成提交的 GitHub Windows / Ubuntu / Flutter 检查均通过。
- [#69](https://github.com/201222-L/dsh-mobile-remote/pull/69)：继续以 develop → main 草稿形式保留。随着 develop 新增改动，范围包括更新器修复、文件浏览/下载、宠物资源及验收文档；不代替维护者合并发布线。

## issue #68：文件范围与下载恢复

已读取正文及贡献者关于远程宿主信任模型的评论。保留从任意新目录创建会话的能力；文件接口继续使用认证后的宿主权限，允许显式路径与符号链接。会话浏览的工作目录边界和 `.git` 列表过滤不是权限隔离。仅限制“已注册工作区”会被同一口令的 cwd 注册入口绕过，不能称为安全修复；真正受限身份需同时设计根目录批准和注册授权。详见 [安全文档](04-security.md)。

新增私有断点与聊天页下载恢复入口。请求发出前先保留任务，响应头及 ETag 先于正文持久化；认证宿主摘要隔离缓存，不把口令写入断点。中断或暂停后按真实文件长度发 Range / If-Range；文件变化则重下，校验完整区间和最终总长度。保存到系统下载目录失败时保留完整私有文件供重试保存。恢复列表支持删除、最多八项，并在下次进入时清理七天前的记录。旧宿主无可靠 ETag 时从头下载。

锁屏中断可能来自 Doze、ROM 网络冻结或进程回收，不能在没有设备现场证据时认定唯一原因。本轮提供中断后可恢复能力，未新增 dataSync 前台服务；该服务仍需考虑 Android 15+ 时限、启动限制和系统撤销。长时间锁屏/进程回收真机验收尚未重做，issue 保持开放。

## issue #58：桌面宠物

正文中的“悬浮球”是旧产品称呼。当前仍是桌面宠物悬浮；已有通知职责收口保留，宠物只呈现宿主未读快照，不发系统业务通知、不自行判断已读或撤销。

将 Android 独立资源迁到 Flutter assets，与首页复用。首页四个动画和四张静态图保持原字节，其它动作迁入；waiting / working_search 内容相同，清单复用一个文件。资源合计 8,716,539 → 6,509,569 字节（减少 25.3%）。清单修正为实际帧数和帧时长，生成脚本输出同一目录并按内容去重。

原生通过 ApplicationInfoLoader 读取 bundle 目录，避免依赖尚未启动的 Dart/Flutter 引擎。资源契约测试校验清单、动画时长、重复内容与包体预算。当前改动尚不能替代真机上的冷恢复、全部动作、减弱动效以及宠物/保活并行场景验收，issue 保持开放。

## issue #20：当前上游复现

截至本轮，npm `next` 为 0.2.1-rc.5、`alpha` 为 0.2.2-alpha.3；`latest` 仍为 0.0.1-rc.1，不能拿 latest 标签代替当前 RC/alpha。两份公开包的 readSession 都调用 Session.create，校验仍要求 inherited cut 处有 end-seed 标记或继承长度等于日志长度。

在 `/tmp` 独立安装 0.2.2-alpha.3 与其依赖，直接运行真实 Session 构造器：无标记、继承一条后追加的合成日志在 snapshot 路径失败；fromRestore 成功；带 inherited end-seed 标记的 snapshot 成功；源数据未变化。没有读取或改写用户 `.zstd` 日志，也没有改动桌面宿主。

可复现命令：`node tools/verify-seeded-session-upstream.mjs <隔离安装的 dsh-session/lib/index.js>`。插件 17 项休眠读取/恢复回归通过，继续保留错误分类、degraded/current-surface 和 configDegraded。贡献者最新反馈是 3.2.0 后未再遇到 session-not-found；它说明插件误报已缓解，不能证明老日志核心缺陷已消失。issue 保持开放跟踪上游。

## issue #60：npm

GitHub 默认更新、可选 npm 来源、配对校验、helper、安装日志和正式签名 CI 已具备；本轮没有重新配置发行基础设施。维护者尚未决定官方 npm scope，实际 npm OIDC 发布和公开分发未验证，不能关闭 issue 或把第三方同名包视为官方来源。本轮继续暂停发布。

## 验证记录

Node 全量 277 项、Python 8 项及 npm run check 通过；最后新增的 ETag 保留 mtime 改写用例所在宿主文件套件 23 项通过。Flutter 全量 692 项通过，最终下载相关 28 项通过，flutter analyze 无问题；真实 TCP 断连后按磁盘断点恢复成功。测试中把原有复制用例的固定 300ms 等待改为有界等待历史加载，避免慢环境误判。

Android debug 构建通过，Kotlin 43 项通过。对实际 APK 逐字节检查所有共享宠物资源与授权，16 个动作引用 15 个唯一动画；旧原生 pet 目录和根清单没有再打包。调试 APK 为 219,796,593 字节，这不是正式签名 release APK，不用于推断正式包总大小，也未安装到手机。构建归档与脱敏验证摘要保存在原仓库 dist 的独立 reliability-review 目录，未覆盖旧产物。

所有新增验证均为自动化或本地独立复现，不计作本轮手机锁屏、公开 CDN 或 npm OIDC 验收。
