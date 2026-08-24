// M2 插件端单测：updateToken 认证（HMAC canonical/时间窗/nonce 去重）、manifest 扫描验签、
// 插件暂存（受限 source/409/幂等/校验失败）。使用一次性测试密钥，不依赖本机 keyring。
import assert from "node:assert";
import { generateKeyPairSync } from "node:crypto";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const repo = pathToFileURL(join(HERE, "..", "lib")).href;
const { canonicalRequest, hmacValue, safeEqual, NonceCache, verifyUpdateAuth } = await import(`${repo}/update-token.js`);
const { scanAndVerifyManifest, stagePluginUpdate, UpdateState, fileInfo } = await import(`${repo}/update-endpoints.js`);
const pubMod = await import(`${repo}/update-crypto.js`);
const pubTool = await import(pathToFileURL(join(HERE, "..", "tools", "publish-update.mjs")).href);
const { buildManifest, signManifest } = pubTool;

let pass = 0, fail = 0;
const check = (name, fn) => { checks.push({ name, fn }); };
const checks = [];

// ── 一次性测试密钥 ──
const mk = () => {
  const pair = generateKeyPairSync("ed25519");
  return { keyId: "test-m2-key", ...pubMod.rawKeysFromKeyPair(pair), active: true };
};
const testKey = mk();
const trusted = new Map([[testKey.keyId, testKey.publicKey]]);

const mkTgz = (content = "m2-plugin-package") => {
  const buf = Buffer.from(content);
  return { buf, size: buf.length, sha256: createHash("sha256").update(buf).digest("hex") };
};
const mkManifest = ({ versionCode = 23, sequence = 9, minAppVersionCode = 15, minPluginVersion = "3.1.0", tgzData }) => {
  const tgz = mkTgz(tgzData);
  const bare = buildManifest({
    versionName: "3.1.0", versionCode, minPluginVersion,
    minAppVersionCode, minKeyringVersionCode: 15,
    channel: "stable",
    apk: { path: "DSH-Remote-v3.1.0.apk", size: 1, sha256: "a".repeat(64) },
    tgz: { path: "dsh-mobile-remote-v3.1.0.tgz", size: tgz.size, sha256: tgz.sha256 },
    sequence,
  });
  const { manifest } = signManifest(bare, [testKey]);
  return { manifest, tgz };
};

// 1. canonical 请求串
check("canonicalRequest 格式（method/path/query/body/ts/nonce 换行分隔，query 排序）", () => {
  const c = canonicalRequest({
    method: "GET", path: "/m/api/update-check",
    query: { b: "2", a: "1" },
    hexBodySha256: "", ts: "1700000000", nonce: "n".repeat(32),
  });
  assert.strictEqual(c, "GET\n/m/api/update-check\na=1&b=2\n\n1700000000\n" + "n".repeat(32));
});

// 2. HMAC 认证
check("verifyUpdateAuth：签名正确通过；错误签名/过期时间/短 nonce/重放 拒绝", () => {
  const token = "T".repeat(32);
  const ts = String(Math.floor(Date.now() / 1000));
  const nonce = "a".repeat(32);
  const path = "/m/api/update-check";
  const bodySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  const canonical = canonicalRequest({ method: "GET", path, query: {}, hexBodySha256: bodySha, ts, nonce });
  const auth = Buffer.from(hmacValue(token, canonical)).toString("base64url");
  const cache = new NonceCache();
  const good = verifyUpdateAuth({
    headers: { "x-update-ts": ts, "x-update-nonce": nonce, "x-update-auth": auth },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: cache,
  });
  assert.strictEqual(good.ok, true);
  // 重放（同 nonce）
  const replay = verifyUpdateAuth({
    headers: { "x-update-ts": ts, "x-update-nonce": nonce, "x-update-auth": auth },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: cache,
  });
  assert.strictEqual(replay.ok, false);
  assert.strictEqual(replay.reason, "nonce-replay");
  // 错误签名
  const bad = verifyUpdateAuth({
    headers: { "x-update-ts": ts, "x-update-nonce": "b".repeat(32), "x-update-auth": "AAAA" },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: new NonceCache(),
  });
  assert.strictEqual(bad.ok, false);
  // 过期时间
  const stale = verifyUpdateAuth({
    headers: { "x-update-ts": String(Math.floor(Date.now() / 1000) - 120), "x-update-nonce": "c".repeat(32), "x-update-auth": "AAAA" },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: new NonceCache(),
  });
  assert.strictEqual(stale.reason, "stale-timestamp");
  // 短 nonce
  const short = verifyUpdateAuth({
    headers: { "x-update-ts": ts, "x-update-nonce": "ab", "x-update-auth": "AAAA" },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: new NonceCache(),
  });
  assert.strictEqual(short.reason, "short-nonce");
});
check("P0 回归：缓存填充攻击——错误签名填满缓存后，合法请求重放仍被拒绝", () => {
  const token = "T".repeat(32);
  const ts = String(Math.floor(Date.now() / 1000));
  const path = "/m/api/update-check";
  const bodySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
  const cache = new NonceCache();
  const mkAuth = (nonce) => {
    const canonical = canonicalRequest({ method: "GET", path, query: {}, hexBodySha256: bodySha, ts, nonce });
    return Buffer.from(hmacValue(token, canonical)).toString("base64url");
  };
  const legitNonce = "l".repeat(32);
  const first = verifyUpdateAuth({
    headers: { "x-update-ts": ts, "x-update-nonce": legitNonce, "x-update-auth": mkAuth(legitNonce) },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: cache,
  });
  assert.strictEqual(first.ok, true);
  // 用 4096 个不同 nonce + 错误签名灌缓存（旧实现会先登记这些 nonce → 挤掉 legitNonce 再重放）
  for (let i = 0; i < 4096; i++) {
    const n = `f${i.toString(16).padStart(31, "0")}`;
    const r = verifyUpdateAuth({
      headers: { "x-update-ts": ts, "x-update-nonce": n, "x-update-auth": "AAAA" },
      method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: cache,
    });
    assert.strictEqual(r.reason, "bad-signature"); // 全部因签名错误被拒，且不得写入缓存
  }
  // 同一条合法请求在 60 秒内重放 → 必须仍被拒绝（legitNonce 未被挤出缓存）
  const replay = verifyUpdateAuth({
    headers: { "x-update-ts": ts, "x-update-nonce": legitNonce, "x-update-auth": mkAuth(legitNonce) },
    method: "GET", path, query: {}, bodyShaHex: bodySha, token, nonceCache: cache,
  });
  assert.strictEqual(replay.ok, false);
  assert.strictEqual(replay.reason, "nonce-replay");
});

// 3. manifest 扫描验签
{
  const { manifest } = mkManifest({});
  const dir = join(tmpdir(), `m2-test-${Date.now()}`);
  mkdirSync(dir, { recursive: true });
  check("scanAndVerifyManifest：合法 manifest（一次性密钥）→ 验签通过", () => {
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(manifest));
    const r = scanAndVerifyManifest(dir, trusted);
    assert.strictEqual(r.verifiedKeyId, "test-m2-key");
    assert.strictEqual(r.manifest.sequence, 9);
  });
  check("scanAndVerifyManifest：篡改（sequence 改 10）→ 抛错", () => {
    const doc = { ...manifest, sequence: 10 };
    writeFileSync(join(dir, "manifest.json"), JSON.stringify(doc));
    assert.throws(() => scanAndVerifyManifest(dir, trusted), /验签失败/);
  });
  check("scanAndVerifyManifest：无 manifest → null", () => {
    rmSync(join(dir, "manifest.json"));
    assert.strictEqual(scanAndVerifyManifest(dir, trusted), null);
  });
}

// 4. 插件暂存
{
  const { manifest, tgz } = mkManifest({ tgzData: "v3.1.0-pkg" });
  const dir = join(tmpdir(), `m2-stage-${Date.now()}`);
  mkdirSync(join(dir), { recursive: true });
  const state = new UpdateState();
  state.updatesDir = dir;
  writeFileSync(join(dir, manifest.artifacts.plugin.fileName), tgz.buf);
  check("stagePluginUpdate：local-cache 暂存成功 + manifest 幂等", async () => {
    const r1 = await stagePluginUpdate({
      manifest, source: "local-cache", declaredAppVersionCode: 20, state, trustedKeys: trusted,
    });
    assert.strictEqual(r1.staged, true);
    const stagedJson = JSON.parse(readFileSync(join(dir, "staged", "9", "staged.json"), "utf8"));
    assert.strictEqual(stagedJson.manifestDigest, r1.manifestDigest);
    const r2 = await stagePluginUpdate({
      manifest, source: "local-cache", declaredAppVersionCode: 20, state, trustedKeys: trusted,
    });
    assert.strictEqual(r2.again, true); // 幂等：不重复下载/复制校验失败
  });
  check("stagePluginUpdate：非法 source → 拒绝", async () => {
    await assert.rejects(
      () => stagePluginUpdate({ manifest, source: "http://evil", declaredAppVersionCode: 20, state, trustedKeys: trusted }),
      /source 不允许/,
    );
  });
  check("stagePluginUpdate：declaredAppVersionCode 低于要求 → 409", async () => {
    await assert.rejects(
      () => stagePluginUpdate({ manifest, source: "local-cache", declaredAppVersionCode: 14, state, trustedKeys: trusted }),
      (e) => e.status === 409,
    );
  });
  check("stagePluginUpdate：篡改 manifest（minAppVersionCode 改 99）→ 验签失败", async () => {
    const doc = { ...manifest, minAppVersionCode: 99 };
    await assert.rejects(
      () => stagePluginUpdate({ manifest: doc, source: "local-cache", declaredAppVersionCode: 20, state, trustedKeys: trusted }),
      /验签失败/,
    );
  });
  check("stagePluginUpdate：包被篡改（同名文件内容不同）→ 校验失败", async () => {
    const dir2 = join(tmpdir(), `m2-tamper-${Date.now()}`);
    mkdirSync(dir2, { recursive: true });
    const s2 = new UpdateState();
    s2.updatesDir = dir2;
    // 覆盖同名 tgz 文件为不同内容（manifest 保持原签名有效 → 应命中产物校验失败）
    writeFileSync(join(dir2, manifest.artifacts.plugin.fileName), Buffer.from("tampered-content"));
    await assert.rejects(
      () => stagePluginUpdate({ manifest, source: "local-cache", declaredAppVersionCode: 20, state: s2, trustedKeys: trusted }),
      /校验失败/,
    );
    rmSync(dir2, { recursive: true, force: true });
  });
}

try {
  for (const c of checks) {
    try {
      await c.fn();
      pass++;
      console.log(`PASS  ${c.name}`);
    } catch (e) {
      fail++;
      console.log(`FAIL  ${c.name} → ${e.message}`);
    }
  }
} finally {
  // 清理临时目录
  for (const d of [join(tmpdir(), `m2-test-${Date.now()}`), join(tmpdir(), `m2-stage-${Date.now()}`)]) {
    try { rmSync(d, { recursive: true, force: true }); } catch {}
  }
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
