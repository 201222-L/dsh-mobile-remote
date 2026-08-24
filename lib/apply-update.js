#!/usr/bin/env node
// M2 helper：插件更新"从暂存到生效"的执行者（外部显式命令 / DSH agent 在用户确认后 spawn）。
// 时序（docs/11 §1/§5.2）：可选 --wait-pid <pid> 等待 DSH 退出后才动手；不等待时要求 DSH 已退出。
// 替换事务（可恢复）：重验签 manifest → 重验 tgz → 解压临时目录 → journal → 同卷 rename 交换 → 备份 → 清理。
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync, mkdirSync, renameSync, rmSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { verifyManifestSignatures, manifestPayloadDigest, trustedReleaseKeys } from "./update-crypto.js";

const DEFAULT_UPDATES = join(homedir(), ".dsh", "mobile-remote", "updates");

/** 等待 PID 退出（进程不存在即视为已退出）。 */
export async function waitForExit(pid, { intervalMs = 2000, check = (p) => { try { process.kill(p, 0); return true; } catch { return false; } } } = {}) {
  for (;;) {
    if (!check(pid)) return; // 已退出或不存在
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

/** 读取最新 staged（按 sequence 最大取一个）。返回 null 表示无。 */
export function findLatestStaged(updatesDir = DEFAULT_UPDATES) {
  const stagedRoot = join(updatesDir, "staged");
  if (!existsSync(stagedRoot)) return null;
  const seqs = readdirSync(stagedRoot)
    .filter((d) => /^\d+$/.test(d))
    .map((d) => Number(d))
    .sort((a, b) => b - a);
  for (const seq of seqs) {
    const stagedJson = join(stagedRoot, String(seq), "staged.json");
    if (!existsSync(stagedJson)) continue;
    try {
      const meta = JSON.parse(readFileSync(stagedJson, "utf8"));
      return { meta, stageDir: join(stagedRoot, String(seq)) };
    } catch { /* 损坏：尝试下一个 */ }
  }
  return null;
}

/** 校验 staged 完整性：manifest 重验签 + digest 一致性 + tgz sha256/size。返回 { manifest, meta }。 */
export function verifyStaged(staged, trustedKeys = trustedReleaseKeys) {
  const { meta, stageDir } = staged;
  const manifestPath = join(stageDir, "manifest.json");
  const tgzPath = join(stageDir, meta.fileName);
  if (!existsSync(manifestPath) || !existsSync(tgzPath)) throw new Error("staged 不完整（缺 manifest 或插件包）");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const without = { ...manifest };
  delete without.signatures;
  const kid = verifyManifestSignatures(without, manifest.signatures, trustedKeys);
  if (!kid) throw new Error("staged manifest 重验签失败");
  if (meta.manifestDigest && manifestPayloadDigest(without) !== meta.manifestDigest) {
    throw new Error("staged manifestDigest 不一致");
  }
  const buf = readFileSync(tgzPath);
  const sha256 = createHash("sha256").update(buf).digest("hex");
  if (sha256 !== meta.sha256 || buf.length !== meta.sizeBytes) throw new Error("staged 插件包校验失败（sha256/size）");
  return { manifest, meta, kid, tgzPath };
}

/** 解压 tgz 到目标目录（系统 tar：Windows 10+ / macOS / Linux 均自带）。 */
export function extractTgz(tgzPath, destDir) {
  mkdirSync(destDir, { recursive: true });
  const r = spawnSync("tar", ["-xf", tgzPath, "-C", destDir], { stdio: "pipe" });
  if (r.status !== 0) {
    throw new Error(`tgz 解压失败（tar exit=${r.status}）：${String(r.stderr ?? "").slice(0, 200)}`);
  }
  // npm pack 产物为 package/ 根目录
  const entries = readdirSync(destDir);
  const pkgDir = entries.includes("package") ? join(destDir, "package") : entries.length === 1 ? join(destDir, entries[0]) : destDir;
  return pkgDir;
}

/** 应用暂存更新（可恢复事务）。
 *  installDir: 插件安装目录（如 profile 的 node_modules/dsh-mobile-remote）。
 *  返回 { ok, backupDir, pkgDir }。 */
export function applyStagedUpdate({ updatesDir = DEFAULT_UPDATES, installDir, trustedKeys = trustedReleaseKeys, logger = console }) {
  const staged = findLatestStaged(updatesDir);
  if (!staged) throw new Error("无已暂存更新（staged 目录为空或不完整）");
  const { manifest, meta, tgzPath } = verifyStaged(staged, trustedKeys);
  if (!installDir || !existsSync(installDir)) throw new Error("插件安装目录不存在：请传 --install-dir");
  const backups = join(updatesDir, "backup");
  const backupDir = join(backups, String(meta.sequence));
  const workDir = join(updatesDir, "tmp", String(meta.sequence));
  const journalPath = join(updatesDir, "tmp", "journal.json");

  // 崩溃恢复：上次未完成事务 → 按状态回滚
  recoverJournal({ updatesDir, installDir, backupDir, workDir, journalPath });

  // 解压到临时目录（不直接写安装路径）
  rmSync(workDir, { recursive: true, force: true });
  const pkgDir = extractTgz(tgzPath, workDir);

  // journal：事务开始
  writeFileSync(journalPath, JSON.stringify({
    phase: "swap-pending", sequence: meta.sequence, installDir, backupDir, workDir, at: new Date().toISOString(),
  }, null, 2) + "\n", "utf8");

  // 同卷 rename 交换：install → backup；tmp-pkg → install
  mkdirSync(backups, { recursive: true }); // 父目录必须存在（Windows rename 目标父路径缺失 → ENOENT）
  rmSync(backupDir, { recursive: true, force: true });
  renameSync(installDir, backupDir);
  renameSync(pkgDir, installDir);

  // 成功：清理 journal / 备份（保留最近 2 份备份）
  rmSync(journalPath, { force: true });
  rmSync(workDir, { recursive: true, force: true });
  pruneBackups(backups, 2);

  logger.info(`mobile-remote: 插件已替换（sequence=${meta.sequence}, 验签=${meta.verifiedKeyId}），备份=${backupDir}；请重新启动 DSH`);
  return { ok: true, backupDir, pkgDir };
}

/** 崩溃恢复：journal 存在 → 恢复上次未完成事务（swap 中断 → 从 backup 复原 install）。 */
export function recoverJournal({ updatesDir, installDir, backupDir, workDir, journalPath }) {
  if (!existsSync(journalPath)) return;
  let j;
  try { j = JSON.parse(readFileSync(journalPath, "utf8")); } catch { rmSync(journalPath, { force: true }); return; }
  const { sequence } = j;
  const bk = join(updatesDir, "backup", String(sequence ?? ""));
  if (existsSync(installDir) && existsSync(bk)) {
    // 交换已发生但未收尾：以备份为准回滚（幂等恢复）
    rmSync(installDir, { recursive: true, force: true });
    renameSync(bk, installDir);
  } else if (!existsSync(installDir) && existsSync(bk)) {
    renameSync(bk, installDir);
  }
  rmSync(workDir, { recursive: true, force: true });
  rmSync(journalPath, { force: true });
}

function pruneBackups(backupsDir, keep) {
  try {
    const dirs = readdirSync(backupsDir).filter((d) => /^\d+$/.test(d)).sort((a, b) => Number(b) - Number(a));
    for (const d of dirs.slice(keep)) rmSync(join(backupsDir, d), { recursive: true, force: true });
  } catch { /* 清理失败不影响主流程 */ }
}

/** CLI：node lib/apply-update.js [--updates-dir D] [--install-dir D] [--wait-pid N] */
export function main(argv) {
  const args = { updatesDir: DEFAULT_UPDATES, installDir: null, waitPid: null };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--updates-dir") args.updatesDir = argv[++i];
    else if (argv[i] === "--install-dir") args.installDir = argv[++i];
    else if (argv[i] === "--wait-pid") args.waitPid = Number(argv[++i]);
    else { console.error(`未知参数：${argv[i]}`); process.exit(1); }
  }
  if (!args.installDir) { console.error("必须指定 --install-dir（插件安装目录，如 <profile>/node_modules/dsh-mobile-remote）"); process.exit(1); }
  const run = async () => {
    if (args.waitPid) {
      console.log(`等待 DSH 进程 ${args.waitPid} 退出…`);
      await waitForExit(args.waitPid);
      console.log("DSH 已退出，开始替换。");
    }
    try {
      const r = applyStagedUpdate({ updatesDir: args.updatesDir, installDir: args.installDir });
      console.log(`✅ 插件已更新（备份保留于 ${r.backupDir}）。请重新启动 DSH。`);
      process.exit(0);
    } catch (e) {
      console.error(`❌ 替换失败：${e.message}`);
      process.exit(1);
    }
  };
  return run();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv);
}
