# 2026-11-04 真机升级验收

## 范围与结果

维护者 USB 直连的小米设备，Android 17 / HyperOS。原手机 App 为 3.2.4-alpha.1+32。本轮完成隔离 Web 插件更新、手机端下载校验、系统安装器覆盖升级至正式签名的 3.2.4-alpha.3+34。首次安装时间仍为 2026-10-29 16:32:08；实际升级时间为 2026-11-04 15:17:39。

全程未停止、升级或改写维护者正在使用的桌面 Harness。本轮未创建标签、GitHub Release 或 npm 发行；维护者明确要求继续暂停发布。

## 验收发现并修复的问题

旧插件退出后，helper 写入 awaiting-start。配对新插件实际启动时，restore 已确认版本一致，但 refresh 又用旧日志覆盖为 awaiting-start，手机因此持续提示“请启动电脑端”，不显示配对 App 安装按钮。

修复仅在日志目标版本、当前运行插件和已经验签恢复的候选版本一致时显示 plugin-ready。旧版本、目标不匹配、失败、回滚和仍在安装的状态继续保留。新增回归用例先复现失败，再修复通过；release-updater 测试 11 项通过。[Ubuntu、Windows、Flutter CI](https://github.com/201222-L/dsh-mobile-remote/actions/runs/41790623577) 全部成功。

alpha.2+33 的原产物保留；修复产物使用 alpha.3+34，未替换同版本内容。构建及清单源码提交：9ba54d680c58f88d25d4bc60a7e0bafa65e06519。

## 实际覆盖

- 使用既有 npm package-lock 的独立 Web profile，从 alpha.1 更新到 alpha.2，复现阻塞，再更新至带修复的 alpha.3。
- 未公开发布，因此只在隔离 Web 进程中模拟 GitHub 列表与附件下载响应，返回本地真实签名清单及产物；生产更新器的验签、哈希、分流下载、helper、npm 安装和恢复逻辑保持原样。
- alpha.2 的检查、下载、准备安装从手机页面触发；alpha.3 重试使用同一宿主 API 准备插件安装，随后验证手机页面显示实际 plugin-ready。
- 退出与重启仅针对测试端口 43181 的 Web 进程。helper 在旧进程退出后实际执行 npm 安装；新进程报告 alpha.3，手机出现“下载并安装配对 App”。
- 手机从真实鉴权 API 下载 APK 到私有缓存；Dart 校验大小/哈希，原生核对实际包名、版本和签名后进入 Android 系统安装器。维护者处理安装来源授权，实际安装版本由 dumpsys package 核实，不能以“启动安装器”代替成功。
- APK 包名 com.dsh.remote；versionName 3.2.4-alpha.3，versionCode 34。Android 证书 SHA-256：c70e4fb6b75fb34f32001f2218ed8898a3871b4c3658e5074c727d4203623dfe，与原正式证书一致。

本轮未覆盖公开 GitHub CDN、npm scope/OIDC、长时间息屏续传，亦未重做全部业务功能验收。

## 数据与收尾

在正式签名临时调试包下私有保存原偏好快照；实际升级过程使用正式包。覆盖升级后，测试连接和 7 项非连接偏好与基线一致。测试期间变化的会话缓存、桌面宠物和保活设置恢复为原值；不能据此宣称所有偏好在整个测试操作期间从未变化。

随后逐字节恢复原地址、原口令、原会话缓存及其他偏好，再装回非调试的正式 alpha.3+34。恢复讯飞输入法、卸载临时输入工具、移除 USB reverse，重置临时安装来源授权；关闭隔离 Web。最后一次界面复核因 USB 断开尚待补做，不影响此前已核实的系统覆盖安装结果。

临时配置快照不提交；脱敏验收摘要与产物归档在本地：
dsh-mobile-app/dist/upgrade-acceptance-3.2.4-alpha.3-build34/，包含 APK、插件 tgz、release-manifest.json 与 device-acceptance.json。目录已忽略，不进入 Git。
