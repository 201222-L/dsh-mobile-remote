// M1 发布工具：生成签名 update manifest（RFC 8785 JCS + Ed25519，支持双签名轮换）
// 用法：
//   node tools/publish-update.mjs init-key [keyId]        # 生成新签名密钥（旧钥默认保持 active，双签名轮换期）
//   node tools/publish-update.mjs retire-key <keyId>     # 轮换结束：停用旧钥
//   node tools/publish-update.mjs list-keys              # 列出密钥（keyId/active/公钥指纹）
//   node tools/publish-update.mjs export-pubkey          # 复写 App 受信公钥常量（lib/update/trusted_keys.dart）
//   node tools/publish-update.mjs publish <apk> <tgz> [--min-plugin-version v] [--min-app-version-code n]
//       [--min-keyring-version-code n] [--channel stable] [--out update.json] [--require-tag]
//       [--bootstrap]        # 首次发布：显式自证，sequence 从 1 开始
//       [--allow-offline]    # 远端账本不可验证时的离线发布（高风险，须同时 --confirm-offline）
// 密钥与发布状态存于 ~/.dsh/mobile-remote/（不进 git）；publicKey 经 export-pubkey 写入 App 源码。
import { generateKeyPairSync, sign, verify, createPrivateKey, createPublicKey } from "node:crypto";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname, basename } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execSync } from "node:child_process";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const STATE_DIR = join(homedir(), ".dsh", "mobile-remote");
const KEYS_DIR = join(STATE_DIR, "release-keys");
const STATE_FILE = join(STATE_DIR, "release-state.json");
const APP_PUBKEY_FILE = join(REPO_ROOT, "dsh-mobile-app", "lib", "update", "trusted_keys.dart");
const GITHUB_OWNER = "201222-L";
const GITHUB_REPO = "dsh-mobile-remote";
const MANIFEST_ASSET = "update.json";

// ── JCS（RFC 8785） ──────────────────────────────────────────────
function jcsString(s) {
  let out = '"';
  for (const ch of s) {
    const cp = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    // RFC 8785 采用 ES6 JSON.stringify 语义：常见控制符用短转义，其余 < 0x20 用 \u00xx（小写）
    else if (ch === "\b") out += "\\b";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\f") out += "\\f";
    else if (ch === "\r") out += "\\r";
    else if (cp < 0x20) out += "\\u" + cp.toString(16).padStart(4, "0");
    else out += ch;
  }
  return out + '"';
}
export function jcs(value) {
  if (value === null) return "null";
  const t = typeof value;
  if (t === "boolean") return value ? "true" : "false";
  if (t === "number") {
    if (!Number.isFinite(value)) throw new Error("JCS: non-finite number");
    if (Object.is(value, -0)) return "0";
    return value.toString(); // ECMAScript Number::toString —— 与 IEEE 双精度解析值一致
  }
  if (t === "string") return jcsString(value);
  if (Array.isArray(value)) return "[" + value.map((v) => jcs(v)).join(",") + "]";
  if (t === "object") {
    const keys = Object.keys(value).sort();
    return "{" + keys.map((k) => jcsString(k) + ":" + jcs(value[k])).join(",") + "}";
  }
  throw new Error(`JCS: unsupported type ${t}`);
}

// ── Ed25519 工具（Node crypto） ──────────────────────────────────
const b64u = (buf) => Buffer.from(buf).toString("base64url");
const fromB64u = (s) => Buffer.from(s, "base64url");
function derTail(buf, n) { return buf.subarray(buf.length - n); }
function rawPubFromSpki(spkiDer) { return derTail(spkiDer, 32); }
function rawSeedFromPkcs8(pkcs8Der) { return derTail(pkcs8Der, 32); }
function privateKeyObject(seedB64u) {
  // RFC 8410 PKCS8 包装 32 字节种子
  const seed = fromB64u(seedB64u);
  const pkcs8 = Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"), seed,
  ]);
  return createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
}
function publicKeyObject(rawB64u) {
  const raw = fromB64u(rawB64u);
  const spki = Buffer.concat([
    Buffer.from("302a300506032b6570032100", "hex"), raw,
  ]);
  return createPublicKey({ key: spki, format: "der", type: "spki" });
}
export function edSign(payload, seedB64u) {
  return sign(null, Buffer.from(payload, "utf8"), privateKeyObject(seedB64u));
}
export function edVerify(payload, signature, rawPubB64u) {
  return verify(null, Buffer.from(payload, "utf8"), publicKeyObject(rawPubB64u), signature);
}

// ── 版本/校验工具 ────────────────────────────────────────────────
export function parseVersion(s) {
  const m = /^(\d+)\.(\d+)\.(\d+)(?:[+-]([\w.-]+))?$/.exec(String(s).trim());
  if (!m) throw new Error(`非法版本号: ${s}`);
  return { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ?? null };
}
export function compareSemver(a, b) {
  const A = parseVersion(a), B = parseVersion(b);
  for (const k of ["major", "minor", "patch"]) {
    if (A[k] !== B[k]) return A[k] > B[k] ? 1 : -1;
  }
  if (A.pre === B.pre) return 0;
  if (A.pre === null) return 1;
  if (B.pre === null) return -1;
  return A.pre > B.pre ? 1 : -1;
}
export function validateVersionIncrease(prev, curr) {
  if (prev !== null && !(curr > prev)) {
    throw new Error(`versionCode 必须严格递增：上次 ${prev}，本次 ${curr}`);
  }
}

// ── 状态与密钥存储 ───────────────────────────────────────────────
function readJson(p) {
  try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; }
}
function writeJson(p, obj) {
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, JSON.stringify(obj, null, 2) + "\n", "utf8");
}
function loadKeys() {
  const keys = [];
  if (existsSync(KEYS_DIR)) {
    for (const f of readdirSync(KEYS_DIR)) {
      if (!f.endsWith(".json")) continue;
      const k = readJson(join(KEYS_DIR, f));
      if (k && k.keyId && k.publicKey && k.privateKey) keys.push(k);
    }
  }
  return keys;
}
function loadState() { return readJson(STATE_FILE) ?? { lastVersionCode: null, lastSequence: 0 }; }
function saveState(state) { writeJson(STATE_FILE, state); }

/** 分页扫描发布账本（可注入 fetchPage 供单测；verifyDoc 校验 manifest 验签）。
 *  complete=false 表示扫描未走完（40 页仍满页/分页异常）→ 调用方必须 fail-closed。 */
export async function scanPublishedLedger({ fetchPage, verifyDoc }) {
  let best = { sequence: null, versionCode: null };
  let complete = false;
  try {
    for (let page = 1; page <= 40; page++) {
      let releases;
      try {
        releases = await fetchPage(page);
      } catch {
        return { ...best, foundAny: false, complete: false };
      }
      if (!Array.isArray(releases)) return { ...best, foundAny: false, complete: false };
      if (releases.length === 0) {
        complete = true;
        break;
      }
      for (const release of releases) {
        const asset = (release.assets ?? []).find((a) => a?.name === MANIFEST_ASSET);
        if (!asset?.browser_download_url) continue;
        try {
          const text = await (await fetch(asset.browser_download_url)).text();
          const doc = JSON.parse(text);
          if (!verifyDoc(doc)) continue;
          const seq = Number(doc.sequence);
          const code = Number(doc.artifacts?.app?.versionCode);
          if (Number.isInteger(seq) && Number.isInteger(code) &&
              (best.sequence === null || seq > best.sequence)) {
            best = { sequence: seq, versionCode: code };
          }
        } catch {
          // 单个 release 校验失败：忽略继续
        }
      }
      if (releases.length < 100) {
        complete = true;
        break;
      }
    }
  } catch {
    return { ...best, foundAny: false, complete: false };
  }
  // 40 页仍然每页满 → 视为不可验证（不把不完整扫描当完整账本）
  if (!complete) return { ...best, foundAny: false, complete: false };
  return { ...best, foundAny: best.sequence !== null, complete: true };
}

/** review3(P1)：从 GitHub **全部**已发布且**验签通过**的 manifest 读取最高 sequence/versionCode。
 *  本地状态只能作缓存。返回 { sequence, versionCode, foundAny, complete }。 */
export async function fetchPublishedState(owner = GITHUB_OWNER, repo = GITHUB_REPO) {
  const keys = loadKeys();
  const trusted = new Map(keys.filter((k) => k.active !== false).map((k) => [k.keyId, k.publicKey]));
  if (!trusted.size) return { sequence: null, versionCode: null, foundAny: false, complete: false };
  const fetchPage = async (page) => {
    const listRes = await fetch(
      `https://api.github.com/repos/${owner}/${repo}/releases?per_page=100&page=${page}`,
      { headers: { accept: "application/vnd.github+json" } },
    );
    if (!listRes.ok) throw new Error(`HTTP ${listRes.status}`);
    return listRes.json();
  };
  const verifyDoc = (doc) => {
    const without = { ...doc };
    delete without.signatures;
    return verifyManifestSignatures(without, doc.signatures, trusted) !== null;
  };
  return scanPublishedLedger({ fetchPage, verifyDoc });
}

/** 发布账本决策（纯函数，供单测）：返回 { effectiveSeq, effectiveCode }；不满足条件抛错（fail-closed）。
 *  --bootstrap 仅允许在远端确认**无任何验签 manifest** 时使用；远端已有账本直接报错。 */
export function resolvePublishLedger({
  remote, lastSequence = null, lastVersionCode = null,
  bootstrap = false, allowOffline = false, confirmOffline = false,
}) {
  if (bootstrap) {
    if (remote?.foundAny) {
      throw new Error(`远端已存在验签发布账本（最高 sequence=${remote.sequence}）：` +
        "--bootstrap 仅允许在远端确认无任何验签 manifest 时使用（防止绕回 sequence=1，老客户端永久拒绝后续更新）");
    }
    if (remote && remote.complete === false) {
      throw new Error("远端账本无法完整验证（分页扫描未走完）：不能确认'无任何验签 manifest'，--bootstrap 拒绝使用");
    }
    return { effectiveSeq: 0, effectiveCode: null };
  }
  if (remote?.foundAny) {
    return {
      effectiveSeq: Math.max(remote.sequence, lastSequence ?? 0),
      effectiveCode: Math.max(remote.versionCode, lastVersionCode ?? null),
    };
  }
  const localValid = (lastSequence ?? 0) > 0;
  if (localValid && allowOffline) {
    if (!confirmOffline) {
      throw new Error("--allow-offline 为高风险离线发布（远端账本不可验证，序列号可能回退）：确认请加 --confirm-offline");
    }
    return { effectiveSeq: lastSequence, effectiveCode: lastVersionCode };
  }
  throw new Error(localValid
    ? "远端发布账本不可验证且未显式 --allow-offline：请联网后重试，或确需离线发布请加 --allow-offline（高风险）"
    : "无远端账本且无本地已验证快照：首次发布请显式 --bootstrap，离线请显式 --allow-offline（高风险）");
}

// ── manifest 构建与签名 ───────────────────────────────────────────
export function buildManifest({ versionName, versionCode, minPluginVersion, minAppVersionCode, minKeyringVersionCode, channel, apk, tgz, sequence, publishedAt }) {
  // 交叉校验（内建不变量，发布脚本与单测共用）
  if (compareSemver(minPluginVersion, versionName) > 0) {
    throw new Error(`交叉校验失败：minPluginVersion ${minPluginVersion} > 插件版本 ${versionName}`);
  }
  if (minAppVersionCode > versionCode) {
    throw new Error(`交叉校验失败：minAppVersionCode ${minAppVersionCode} > App versionCode ${versionCode}`);
  }
  if (minKeyringVersionCode != null && minKeyringVersionCode > versionCode) {
    throw new Error(`交叉校验失败：minKeyringVersionCode ${minKeyringVersionCode} > App versionCode ${versionCode}`);
  }
  const manifest = {
    schemaVersion: 1,
    sequence,
    channel: channel ?? "stable",
    publishedAt: publishedAt ?? new Date().toISOString(),
    minPluginVersion,
    minAppVersionCode,
    ...(minKeyringVersionCode != null ? { minKeyringVersionCode } : {}),
    artifacts: {
      app: {
        artifactId: "dsh-remote-apk",
        fileName: basename(apk.path),
        versionName,
        versionCode,
        sizeBytes: apk.size,
        sha256: apk.sha256,
      },
      plugin: {
        artifactId: "dsh-remote-plugin",
        fileName: basename(tgz.path),
        versionName,
        sizeBytes: tgz.size,
        sha256: tgz.sha256,
      },
    },
  };
  return manifest;
}
export function signManifest(manifest, keys) {
  const payload = jcs(manifest); // 不含 signatures
  const signatures = keys
    .filter((k) => k.active !== false)
    .map((k) => ({ keyId: k.keyId, signature: b64u(edSign(payload, k.privateKey)) }));
  return { manifest: { ...manifest, signatures }, payload, signatures };
}
export function verifyManifestSignatures(manifestWithoutSigs, signatures, trustedKeys) {
  // trustedKeys: Map<keyId, rawPubB64u>。要求至少一个签名项 keyId 命中且验签通过。
  const payload = jcs(manifestWithoutSigs);
  for (const s of signatures ?? []) {
    const pub = trustedKeys?.get(s?.keyId);
    if (!pub) continue;
    try {
      if (edVerify(payload, fromB64u(s.signature), pub)) return s.keyId;
    } catch { /* 该签名项非法，继续尝试其它 */ }
  }
  return null;
}

// ── 文件信息 ─────────────────────────────────────────────────────
function fileInfo(p) {
  const buf = readFileSync(p);
  return { path: p, size: buf.length, sha256: createHash("sha256").update(buf).digest("hex") };
}

// ── 命令实现 ─────────────────────────────────────────────────────
function cmdInitKey(args) {
  const keyId = args[0] ?? `dsh-release-${new Date().getFullYear()}`;
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const pubRaw = rawPubFromSpki(publicKey.export({ type: "spki", format: "der" }));
  const seedRaw = rawSeedFromPkcs8(privateKey.export({ type: "pkcs8", format: "der" }));
  const rec = {
    keyId,
    publicKey: b64u(pubRaw),
    privateKey: b64u(seedRaw),
    active: true,
    createdAt: new Date().toISOString(),
  };
  writeJson(join(KEYS_DIR, `${keyId}.json`), rec);
  console.log(`已生成密钥 ${keyId}（active）。轮换期内旧钥保持 active 可实现双签名；完成后用 retire-key 停用。`);
  console.log(`publicKey(base64url): ${rec.publicKey}`);
}
function cmdRetireKey(args) {
  const keyId = args[0];
  if (!keyId) throw new Error("retire-key 需要 keyId");
  const p = join(KEYS_DIR, `${keyId}.json`);
  const k = readJson(p);
  if (!k) throw new Error(`密钥不存在: ${keyId}`);
  k.active = false;
  writeJson(p, k);
  console.log(`已停用 ${keyId}（后续发布不再用它签名）`);
}
function cmdListKeys() {
  const keys = loadKeys();
  if (!keys.length) { console.log("（无密钥）先用 init-key 生成"); return; }
  for (const k of keys) {
    const fp = createHash("sha256").update(fromB64u(k.publicKey)).digest("hex").slice(0, 16);
    console.log(`${k.keyId}  active=${k.active !== false}  pub=${k.publicKey.slice(0, 12)}…  fp=${fp}`);
  }
}
function cmdExportPubkey() {
  const keys = loadKeys().filter((k) => k.active !== false);
  if (!keys.length) throw new Error("无 active 密钥");
  const entries = keys.map((k) => `  '${k.keyId}': '${k.publicKey}',`).join("\n");
  const dart = `// 自动生成：受信发布公钥集（勿手改）。由 tools/publish-update.mjs export-pubkey 维护。\n// 换钥时新钥随发布附双签名，客户端按 keyId 匹配验签；旧钥移除后删除对应条目。\nconst Map<String, String> trustedReleaseKeys = <String, String>{\n${entries}\n};\n`;
  mkdirSync(dirname(APP_PUBKEY_FILE), { recursive: true });
  writeFileSync(APP_PUBKEY_FILE, dart, "utf8");
  console.log(`已写入 ${APP_PUBKEY_FILE}`);
}
function cmdPublish(args, opts) {
  if (args.length < 2) throw new Error("publish 需要 <apk路径> <tgz路径>");
  const pubspec = readFileSync(join(REPO_ROOT, "dsh-mobile-app", "pubspec.yaml"), "utf8");
  const vm = /^version:\s*(\S+)/m.exec(pubspec);
  if (!vm) throw new Error("pubspec 未找到 version");
  const [versionName, versionCodeStr] = vm[1].split("+");
  const versionCode = Number(versionCodeStr);
  if (!Number.isInteger(versionCode) || versionCode < 1) throw new Error(`versionCode 非法: ${vm[1]}`);
  const pkgJson = JSON.parse(readFileSync(join(REPO_ROOT, "package.json"), "utf8"));
  if (pkgJson.version !== versionName) throw new Error(`三处版本不一致：package.json=${pkgJson.version} ≠ pubspec=${versionName}`);
  if (opts["require-tag"]) {
    try {
      execSync(`git -C "${REPO_ROOT}" rev-parse --verify "v${versionName}"`, { stdio: "pipe" });
    } catch {
      throw new Error(`tag v${versionName} 不存在（--require-tag 开启）`);
    }
  }
  const state = loadState();
  // M1 review3(P1)：发布账本 fail-closed——决策在 resolvePublishLedger（纯函数，单测覆盖）
  const doPublish = (remoteBest) => {
    const { effectiveSeq, effectiveCode } = resolvePublishLedger({
      remote: remoteBest,
      lastSequence: state.lastSequence ?? null,
      lastVersionCode: state.lastVersionCode ?? null,
      bootstrap: Boolean(opts["bootstrap"]),
      allowOffline: Boolean(opts["allow-offline"]),
      confirmOffline: Boolean(opts["confirm-offline"]),
    });
    if (opts["bootstrap"]) console.warn("⚠️ --bootstrap：远端确认无验签 manifest，sequence 从 1 开始");
    validateVersionIncrease(effectiveCode, versionCode);
    const sequence = effectiveSeq + 1;
    const minPluginVersion = opts["min-plugin-version"] ?? versionName;
    const minAppVersionCode = Number(opts["min-app-version-code"] ?? versionCode);
    const minKeyringVersionCode = opts["min-keyring-version-code"] != null ? Number(opts["min-keyring-version-code"]) : null;
    const keys = loadKeys().filter((k) => k.active !== false);
    if (!keys.length) throw new Error("无 active 签名密钥：先 init-key");
    const apk = fileInfo(args[0]);
    const tgz = fileInfo(args[1]);
    const bare = buildManifest({ versionName, versionCode, minPluginVersion, minAppVersionCode, minKeyringVersionCode, channel: opts["channel"], apk, tgz, sequence });
    const { manifest, payload } = signManifest(bare, keys);
    const out = opts["out"] ?? "update.json";
    writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n", "utf8");
    saveState({ lastVersionCode: versionCode, lastSequence: sequence, lastTag: `v${versionName}` });
    console.log(`已生成 ${out}`);
    console.log(`  app:    ${versionName}+${versionCode} (${apk.sha256.slice(0, 16)}…)`);
    console.log(`  plugin: ${versionName} (${tgz.sha256.slice(0, 16)}…)`);
    console.log(`  sequence=${sequence}（远端最高 ${remoteBest?.sequence ?? "无"}） 签名=${keys.length} 份（${keys.map((k) => k.keyId).join(", ")}）`);
    console.log(`  canonical payload 长度=${payload.length}`);
  };
  return fetchPublishedState().then(doPublish);
}

// ── CLI ──────────────────────────────────────────────────────────
async function runCli() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  const opts = {};
  const args = [];
  for (let i = 1; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next && !next.startsWith("--")) { opts[key] = next; i++; }
      else opts[key] = true;
    } else args.push(argv[i]);
  }
  const handlers = { "init-key": cmdInitKey, "retire-key": cmdRetireKey, "list-keys": cmdListKeys, "export-pubkey": cmdExportPubkey, publish: cmdPublish };
  if (!handlers[cmd]) {
    console.log("用法: node tools/publish-update.mjs <init-key|retire-key|list-keys|export-pubkey|publish> [参数]");
    process.exit(1);
  }
  try {
    await handlers[cmd](args, opts);
  } catch (e) {
    console.error(`[发布工具错误] ${e.message}`);
    process.exit(1);
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) runCli();
