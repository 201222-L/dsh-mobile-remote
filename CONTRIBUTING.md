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
