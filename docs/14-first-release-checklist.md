# 第一次发布前的当前步骤

已完成：`release` 环境、main / `v*` 范围规则、Android 签名四项 Secrets、更新清单私钥 Secret、`RELEASE_KEY_ID`。本地已验证更新清单私钥与客户端信任公钥匹配。npm scope 暂未决定，不影响 GitHub 来源的构建与发布。

现在执行：审阅并合并 [PR #64](https://github.com/201222-L/dsh-mobile-remote/pull/64)，让工作流进入默认 main 分支。合并本身只运行 Checks，不会公开发布。

合并后打开 [Actions](https://github.com/201222-L/dsh-mobile-remote/actions)，选择 **Prepare and publish release → Run workflow**：

| 字段 | 第一次演练填写 |
|---|---|
| Use workflow from | `main` |
| source_ref | `main` |
| tag | 留空 |
| publish | 未勾选 |

完成后进入该次运行，下方 **Artifacts → signed-release-v<版本>** 下载 APK、插件 tgz 和签名清单。这个过程使用 GitHub Secrets，可确认五项签名配置在干净 CI 环境中确实可用。本地通过或 Secrets 名称齐全，都不能代替这一次云端完整演练。

确认产物与真机验收后再决定公开发布；App 下一次覆盖升级要求 versionCode 大于手机现有 build 32。公开发布必须手动填写 main 上的已有版本标签并勾选 publish；新版本内容不得覆盖旧版。首次公开发布前保持 npm scope 未配置即可只发 GitHub。
