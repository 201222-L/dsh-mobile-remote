#!/usr/bin/env node
// M2：电脑源 updateToken 轮换/查看（本地执行；轮换后旧值立即失效，App 侧提示重新扫码配对）。
// 用法：node bin/dsh-remote-tokens.mjs rotate | show
import { getUpdateToken, rotateUpdateToken } from "../lib/update-token.js";

const cmd = process.argv[2] ?? "show";
if (cmd === "rotate") {
  const next = rotateUpdateToken();
  console.log(`updateToken 已轮换（旧值失效）。请让手机端重新扫码配对（设置 → 重新配置连接 → 扫码）。`);
  console.log(`新 token（如手动配置使用）：${next}`);
} else if (cmd === "show") {
  console.log(getUpdateToken());
} else {
  console.log("用法：node bin/dsh-remote-tokens.mjs rotate | show");
  process.exit(1);
}
