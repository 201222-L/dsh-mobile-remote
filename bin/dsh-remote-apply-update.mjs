#!/usr/bin/env node
// M2 helper CLI：应用暂存更新（可恢复替换事务）。
// 用法：dsh-remote-apply-update [--updates-dir D] [--install-dir D] [--wait-pid PID]
//   --wait-pid：传入 DSH 进程 PID（agent 代执行时由启动方获取当前宿主 PID），
//               helper 会等待该进程退出后才执行替换（宿主内 agent 不得直接替换文件）。
import { main } from "../lib/apply-update.js";
main(process.argv);
