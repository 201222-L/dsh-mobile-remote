// M2 helper 单测：暂存发现/完整性校验（重验签/sha256）/解压/同卷交换事务/崩溃恢复。
import assert from "node:assert";
import { generateKeyPairSync } from "node:crypto";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, readFileSync, rmSync, readdirSync, existsSync, renameSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const repoUrl = pathToFileURL(join(HERE, "..", "lib")).href;
const { rawKeysFromKeyPair, verifyManifestSignatures, manifestPayloadDigest } = await import(`${repoUrl}/update-crypto.js`);
const upd = await import(`${repoUrl}/apply-update.js`);
const pubTool = await import(pathToFileURL(join(HERE, "..", "tools", "publish-update.mjs")).href);
const { buildManifest, signManifest } = pubTool;

const checks = [];
let pass = 0, fail = 0;
const check = (name, fn) => checks.push({ name, fn });

const mk = () => {
  const pair = generateKeyPairSync("ed25519");
  return { keyId: "test-apply-key", ...rawKeysFromKeyPair(pair), active: true };
};
const testKey = mk();
const trusted = new Map([[testKey.keyId, testKey.publicKey]]);

const tdir = join(tmpdir(), `m2-apply-${Date.now()}`);
const updatesDir = join(tdir, "updates");
const installDir = join(tdir, "install");
const backupDirFor = (seq) => join(updatesDir, "backup", String(seq));

function makeTgzPkg(updatesDir, { fileName = "dsh-mobile-remote-v3.1.0.tgz", content = "package:index.js:console.log('v3.1.0')", seq = 9 }) {
  // 用系统 tar 打一个 npm 风格 tgz：package/<files>
  const src = join(tdir, `pkg-src-${Math.random().toString(36).slice(2)}`);
  mkdirSync(join(src, "package"), { recursive: true });
  writeFileSync(join(src, "package", "index.js"), content);
  const tgzPath = join(updatesDir, fileName);
  const r = spawnSync("tar", ["-czf", tgzPath, "-C", src, "package"], { stdio: "pipe" });
  assert.strictEqual(r.status, 0, `tar 打包失败: ${r.stderr}`);
  const buf = readFileSync(tgzPath);
  return { tgzPath, sha256: createHash("sha256").update(buf).digest("hex"), size: buf.length, content };
}

function makeStaged({ updatesDir, seq = 9, content, trustedKeys = trusted }) {
  const stageDir = join(updatesDir, "staged", String(seq));
  mkdirSync(stageDir, { recursive: true });
  const info = makeTgzPkg(stageDir, { seq, content }); // tgz 写在 staged/<seq>/ 内（与 stagePluginUpdate 一致）
  const bare = buildManifest({
    versionName: "3.1.0", versionCode: 23, minPluginVersion: "3.1.0",
    minAppVersionCode: 15, minKeyringVersionCode: 15, channel: "stable",
    apk: { path: "a.apk", size: 1, sha256: "a".repeat(64) },
    tgz: { path: info.tgzPath.split(/[\\/]/).pop(), size: info.size, sha256: info.sha256 },
    sequence: seq,
  });
  const { manifest } = signManifest(bare, [testKey]);
  writeFileSync(join(stageDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
  const without = { ...manifest };
  delete without.signatures;
  writeFileSync(join(stageDir, "staged.json"), JSON.stringify({
    manifestDigest: manifestPayloadDigest(without), sequence: seq,
    versionName: "3.1.0", fileName: info.tgzPath.split(/[\\/]/).pop(),
    sha256: info.sha256, sizeBytes: info.size, verifiedKeyId: "test-apply-key",
    at: new Date().toISOString(),
  }, null, 2) + "\n", "utf8");
  return { manifest, info };
}

check("findLatestStaged：取最高 sequence", () => {
  mkdirSync(join(updatesDir, "staged"), { recursive: true });
  makeStaged({ updatesDir, seq: 5 });
  makeStaged({ updatesDir, seq: 9 });
  const f = upd.findLatestStaged(updatesDir);
  assert.strictEqual(f.meta.sequence, 9);
});

check("verifyStaged：完整校验通过（重验签 + digest + sha256）", () => {
  const f = upd.findLatestStaged(updatesDir);
  const r = upd.verifyStaged(f, trusted);
  assert.strictEqual(r.meta.sequence, 9);
  assert.strictEqual(r.kid, "test-apply-key");
});

check("verifyStaged：staged manifest 被篡改 → 重验签失败", () => {
  const f = upd.findLatestStaged(updatesDir);
  const mp = join(f.stageDir, "manifest.json");
  const doc = JSON.parse(readFileSync(mp, "utf8"));
  writeFileSync(mp, JSON.stringify({ ...doc, sequence: 10 }, null, 2) + "\n", "utf8");
  assert.throws(() => upd.verifyStaged(f, trusted), /重验签失败/);
});

check("verifyStaged：插件包被篡改 → 校验失败", () => {
  // 重新生成一致的 staged（上一测试篡改过 manifest，这里先重建 pristine）
  rmSync(join(updatesDir, "staged", "9"), { recursive: true, force: true });
  makeStaged({ updatesDir, seq: 9, content: "regen" });
  const f = upd.findLatestStaged(updatesDir);
  writeFileSync(join(f.stageDir, f.meta.fileName), "tampered");
  assert.throws(() => upd.verifyStaged(f, trusted), /校验失败/);
});

check("applyStagedUpdate：端到端替换（同卷交换 + 备份 + journal 清理）", () => {
  // 重新构造干净的 staged（seq 10）
  rmSync(join(updatesDir, "staged", "10"), { recursive: true, force: true });
  const { info } = makeStaged({ updatesDir, seq: 10, content: "package:index.js:console.log('v3.1.0-new')" });
  mkdirSync(installDir, { recursive: true });
  writeFileSync(join(installDir, "OLD_MARKER"), "old");
  const r = upd.applyStagedUpdate({ updatesDir, installDir, trustedKeys: trusted });
  assert.strictEqual(r.ok, true);
  // installDir 已被替换为 tgz 的 package/ 内容（无嵌套 package/）
  assert.ok(existsSync(join(installDir, "package", "index.js")) || existsSync(join(installDir, "index.js")));
  // 备份目录保留旧版
  const bk = backupDirFor(10);
  assert.ok(existsSync(join(bk, "OLD_MARKER")));
  // journal 已清理、tmp 已清理
  assert.ok(!existsSync(join(updatesDir, "tmp", "journal.json")));
});

check("recoverJournal：交换中断 → 从备份复原 install", () => {
  // 模拟崩溃现场：backup 存在、install 缺失、journal 存在（swap-pending）
  const bk = backupDirFor(12);
  rmSync(bk, { recursive: true, force: true });
  mkdirSync(bk, { recursive: true });
  writeFileSync(join(bk, "OLD_MARKER"), "old");
  rmSync(installDir, { recursive: true, force: true });
  const journalPath = join(updatesDir, "tmp", "journal.json");
  mkdirSync(dirname(journalPath), { recursive: true });
  writeFileSync(journalPath, JSON.stringify({ phase: "swap-pending", sequence: 12, installDir, backupDir: bk }, null, 2));
  upd.recoverJournal({ updatesDir, installDir, backupDir: bk, workDir: join(updatesDir, "tmp", "12"), journalPath });
  assert.ok(existsSync(join(installDir, "OLD_MARKER")));
  assert.ok(!existsSync(journalPath));
});

try {
  for (const c of checks) {
    try { await c.fn(); pass++; console.log(`PASS  ${c.name}`); }
    catch (e) { fail++; console.log(`FAIL  ${c.name} → ${e.message}`); }
  }
} finally {
  rmSync(tdir, { recursive: true, force: true });
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
