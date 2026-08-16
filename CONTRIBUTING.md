# 贡献指南

欢迎任何形式的贡献：提 issue、修 bug、加功能、补文档、二次开发。

## 参与方式

- **报告问题**：GitHub Issues —— 说明环境（dsh 版本 / 平台）、操作步骤、现象；移动端问题附截图更佳
- **提交代码**：Fork → 分支 → PR；小改动直接 PR，大功能先开 issue 讨论
- **文档**：README / docs/ 的任何改进都欢迎
- **二次开发**：见 `docs/08-扩展开发指南.md` —— 欢迎基于本项目做自己的定制并回馈上游

## 开发环境

- **插件**：Node.js 18+；在 `~/.dsh/profiles/web` 以 `file:` 依赖引入（见 docs/06-install-run.md）
- **App**：Flutter 3.47+ + Android SDK；`flutter analyze` 必须零问题

## 代码约定

- 插件：ESM，遵循现有 `lib/index.js` 的风格；新端点必须在 `docs/03-api.md` 补文档
- 原型：`prototype/app-prototype.html`（设计参考，零构建，改完直接刷新浏览器看效果）
- App：`flutter analyze` 零 warning；UI 使用 `theme.dart` 设计令牌，不硬编码颜色
- 提交信息：中文或英文均可，一句话说明改动（如 `fix: SSE 解析死循环`）
- 兼容边界：改动涉及内核服务依赖时，对照 `docs/09-compatibility.md` 的降级约定

## 测试要求

- 插件改动：跑 `tools/e2e-check.mjs`（需 `DSH_MOBILE_TOKEN` 环境变量）
- App 改动：`flutter analyze` + 真机冒烟（发消息/收通知/新建会话）
- 新端点：在 `docs/05-test-cases.md` 补用例

## 安全底线

- 任何新端点默认走统一鉴权；敏感数据（口令/二维码）只允许 loopback 读取
- 不引入公网暴露；见 `docs/04-security.md`

## 发布新版本（维护者清单）

**插件改动（电脑端）**：改 `lib/index.js` → `node --check` → 同步安装目录并重启实测 → `package.json` 版本号 → CHANGELOG 条目。

**App 改动（手机端）**：改代码 → `flutter analyze` + `flutter test` → `flutter build apk --release` + 真机实测 → `pubspec.yaml` 版本号（形如 `2.4.3+1`）。

**共同步骤**：
1. 文档同步（API/行为变化时更新 docs/03 等）
2. `git commit`（一句话说明改动）+ `git push origin main`
3. `git tag -a vX.Y.Z -m "..."` + `git push origin main --tags`
4. **本地归档**：`flutter build apk --release` 后运行 `dsh-mobile-app\tools\package-release.ps1` → 生成 `dist\DSH-Remote-vX.Y.Z.apk`（带版本号，dist/ 已 gitignore，本机永久保留）
5. GitHub 网页创建 **Release**：选新 tag → 标题 `DSH Remote vX.Y.Z` → 说明写清本次改动 → **上传 dist 里带版本号的那个 APK**
6. 大更新在 DSH 社区发帖；CHANGELOG 保持完整历史

**版本保留原则**：
- **旧版 Release 永远保留不删**——它们是版本历史，用户可自行选择下载任一版本回退；每次只**新增**一条 Release（选新 tag），新版本自动成为 Latest
- 每次 App 改动**必须同步 bump `pubspec.yaml` 版本号**（`X.Y.Z+N`），否则新旧包版本号相同、无法区分；开发者本地构建也遵循同一版本号，便于对照 Release 排查
- 同一签名覆盖安装，用户升级无痛；换 keystore 除外（= 换应用）

> 提醒：手机侧载安装无自动更新，重要修复在 Release 说明里写醒目；**不要更换签名 keystore**（同签名覆盖安装保留连接信息）。
