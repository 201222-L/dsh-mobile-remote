// M1 发布工具验证：RFC 8785 金样本 / 密钥往返 / 签名往返（含双签名）/ 交叉校验与递增校验失败路径
import assert from "node:assert";
import { jcs, edSign, edVerify, compareSemver, validateVersionIncrease, buildManifest, signManifest, verifyManifestSignatures, parseVersion, resolvePublishLedger, scanPublishedLedger } from "./publish-update.mjs";
import { generateKeyPairSync } from "node:crypto";

let pass = 0, fail = 0;
// review4：执行器改为收集后逐个 await——async 测试的断言失败必须计入 fail（此前异步用例未等待=假绿）
const checks = [];
const check = (name, fn) => checks.push({ name, fn });

// 1. RFC 8785 附录 A 金样本（参考实现 README 的已知向量）
check("JCS RFC8785 金样本", () => {
  const input = {
    numbers: [333333333.33333329, 1e30, 4.5, 0.002, 1e-27],
    string: "€$\u000f\nA'B\"\\\\\"/",
    literals: [null, true, false],
  };
  // String.raw：背斜杠原样保留，与参考实现 README 的已知向量逐字一致
  const expected = String.raw`{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}`;
  assert.strictEqual(jcs(input), expected);
});
check("JCS 键排序与嵌套", () => {
  assert.strictEqual(jcs({ b: 1, a: { d: 2, c: [3, null, true] } }), `{"a":{"c":[3,null,true],"d":2},"b":1}`);
});
check("JCS 字符串转义（控制字符/引号/反斜杠）", () => {
  assert.strictEqual(jcs("a\u0001\"\\b"), `"a\\u0001\\"\\\\b"`);
});

// 2. Ed25519 密钥往返 + 签名往返
let keyA = null, keyB = null;
{
  const mk = () => {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const spki = publicKey.export({ type: "spki", format: "der" });
    const pkcs8 = privateKey.export({ type: "pkcs8", format: "der" });
    return {
      publicKey: Buffer.from(spki.subarray(spki.length - 32)).toString("base64url"),
      privateKey: Buffer.from(pkcs8.subarray(pkcs8.length - 32)).toString("base64url"),
    };
  };
  keyA = { keyId: "k1", ...mk(), active: true };
  keyB = { keyId: "k2", ...mk(), active: true };
}
check("Ed25519 签名/验签往返（密钥 A）", () => {
  const payload = "hello-canonical";
  const sig = edSign(payload, keyA.privateKey);
  assert.strictEqual(edVerify(payload, sig, keyA.publicKey), true);
});
check("Ed25519 错误公钥/篡改载荷拒绝", () => {
  const payload = "hello-canonical";
  const sig = edSign(payload, keyA.privateKey);
  assert.strictEqual(edVerify(payload, sig, keyB.publicKey), false);
  assert.strictEqual(edVerify(payload + "x", sig, keyA.publicKey), false);
});

// 3. manifest 构建 + 双签名 + 验签
check("manifest 双签名与验签（两个 keyId 各自可验）", () => {
  const apk = { path: "DSH-Remote-v3.1.0.apk", size: 100, sha256: "a".repeat(64) };
  const tgz = { path: "dsh-mobile-remote-v3.1.0.tgz", size: 200, sha256: "b".repeat(64) };
  const bare = buildManifest({
    versionName: "3.1.0", versionCode: 15,
    minPluginVersion: "3.0.0", minAppVersionCode: 14, minKeyringVersionCode: 15,
    channel: "stable", apk, tgz, sequence: 3,
  });
  assert.strictEqual(bare.signatures, undefined);
  const { manifest, signatures, payload } = signManifest(bare, [keyA, keyB]);
  assert.strictEqual(signatures.length, 2);
  const without = { ...manifest };
  delete without.signatures;
  assert.strictEqual(jcs(without), payload); // canonical 一致性
  const trusted = new Map([[keyA.keyId, keyA.publicKey], [keyB.keyId, keyB.publicKey]]);
  assert.strictEqual(verifyManifestSignatures(without, manifest.signatures, trusted), "k1");
  // 仅信任 keyB（模拟旧钥已移除）也能验
  assert.strictEqual(verifyManifestSignatures(without, manifest.signatures, new Map([[keyB.keyId, keyB.publicKey]])), "k2");
  // 全不信任 → null
  assert.strictEqual(verifyManifestSignatures(without, manifest.signatures, new Map()), null);
  // 篡改 payload → null
  const bad = { ...without, sequence: 4 };
  assert.strictEqual(verifyManifestSignatures(bad, manifest.signatures, trusted), null);
});

// 4. 版本工具
check("compareSemver（含 pre-release）", () => {
  assert.strictEqual(compareSemver("3.1.0", "3.0.9"), 1);
  assert.strictEqual(compareSemver("3.1.0", "3.1.0"), 0);
  assert.strictEqual(compareSemver("3.1.0-rc.1", "3.1.0"), -1);
  assert.strictEqual(compareSemver("3.1.0", "3.1.0-rc.1"), 1);
});
check("parseVersion 严格性", () => {
  assert.deepStrictEqual(parseVersion("3.1.0+15"), { major: 3, minor: 1, patch: 0, pre: "15" });
  assert.throws(() => parseVersion("3.1"));
});

// 5. 校验失败路径
check("versionCode 非递增拒绝 / 递增通过", () => {
  assert.throws(() => validateVersionIncrease(15, 15));
  assert.throws(() => validateVersionIncrease(16, 15));
  validateVersionIncrease(14, 15);
  validateVersionIncrease(null, 15);
});
check("交叉校验失败拒绝（minAppVersionCode > versionCode）", () => {
  assert.throws(() => buildManifest({
    versionName: "3.1.0", versionCode: 15,
    minPluginVersion: "3.0.0", minAppVersionCode: 16,
    apk: { path: "x.apk", size: 1, sha256: "c".repeat(64) },
    tgz: { path: "x.tgz", size: 1, sha256: "d".repeat(64) },
    sequence: 3,
  }), /minAppVersionCode/);
});

// 6. review3：resolvePublishLedger（发布账本 fail-closed 决策）
check("--bootstrap 遇已有远端账本 → 拒绝（不得绕回 sequence=1）", () => {
  assert.throws(
    () => resolvePublishLedger({ remote: { sequence: 7, versionCode: 23, foundAny: true, complete: true }, bootstrap: true }),
    /验签发布账本/,
  );
});
check("--bootstrap 远端不可完整验证 → 拒绝", () => {
  assert.throws(
    () => resolvePublishLedger({ remote: { sequence: null, versionCode: null, foundAny: false, complete: false }, bootstrap: true }),
    /无法完整验证/,
  );
});
check("--bootstrap（远端确认无账本）→ 从 sequence=1 开始", () => {
  assert.deepStrictEqual(
    resolvePublishLedger({ remote: { sequence: null, versionCode: null, foundAny: false, complete: true }, bootstrap: true }),
    { effectiveSeq: 0, effectiveCode: null },
  );
});
check("远端有账本 → 取远端与本地快照的较大值", () => {
  assert.deepStrictEqual(
    resolvePublishLedger({ remote: { sequence: 7, versionCode: 23, foundAny: true, complete: true }, lastSequence: 5, lastVersionCode: 21 }),
    { effectiveSeq: 7, effectiveCode: 23 },
  );
  assert.deepStrictEqual(
    resolvePublishLedger({ remote: { sequence: 7, versionCode: 23, foundAny: true, complete: true }, lastSequence: 9, lastVersionCode: 25 }),
    { effectiveSeq: 9, effectiveCode: 25 },
  );
});
check("离线发布：未显式 allow-offline → 拒绝；缺 confirm-offline → 拒绝", () => {
  assert.throws(
    () => resolvePublishLedger({ remote: { sequence: null, versionCode: null, foundAny: false, complete: false }, lastSequence: 5, lastVersionCode: 21 }),
    /allow-offline/,
  );
  assert.throws(
    () => resolvePublishLedger({ remote: { sequence: null, versionCode: null, foundAny: false, complete: false }, lastSequence: 5, allowOffline: true }),
    /confirm-offline/,
  );
});
check("离线发布：双标志齐全且无远端账本 → 用本地快照", () => {
  assert.deepStrictEqual(
    resolvePublishLedger({ remote: { sequence: null, versionCode: null, foundAny: false, complete: false }, lastSequence: 5, lastVersionCode: 21, allowOffline: true, confirmOffline: true }),
    { effectiveSeq: 5, effectiveCode: 21 },
  );
});
check("无远端无本地且未 bootstrap → 拒绝", () => {
  assert.throws(
    () => resolvePublishLedger({ remote: { sequence: null, versionCode: null, foundAny: false, complete: true }, lastSequence: null }),
    /首次发布请显式 --bootstrap/,
  );
});

// 7. review3：scanPublishedLedger（分页扫描完整性，fail-closed）
check("分页扫描：页码正常走完（有不满页）→ complete=true", async () => {
  // release 对象必须合法（{ assets: [...] }）；不含 update.json 资产的 release 会被跳过
  const fetchPage = async (page) => (page === 1 ? Array(100).fill({ assets: [] }) : [{ assets: [] }]);
  const r = await scanPublishedLedger({ fetchPage, verifyDoc: () => true });
  assert.strictEqual(r.complete, true);
});
check("分页扫描：40 页仍每页满 100 → 不完整扫描 fail-closed", async () => {
  const full = Array(100).fill({ assets: [] });
  const r = await scanPublishedLedger({ fetchPage: async () => full, verifyDoc: () => true });
  assert.strictEqual(r.complete, false);
  assert.strictEqual(r.foundAny, false);
});
check("分页扫描：分页请求异常（限流/网络）→ fail-closed", async () => {
  const r = await scanPublishedLedger({
    fetchPage: async () => { throw new Error("rate limited"); },
    verifyDoc: () => true,
  });
  assert.strictEqual(r.complete, false);
  assert.strictEqual(r.foundAny, false);
});

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

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
