// M2 共享加密模块（随 npm 包发布，files 白名单必须包含本文件）。
// 提供：RFC 8785 JCS、Ed25519 签名/验签、manifest 验签、受信公钥表。
// 消费方：tools/publish-update.mjs（发布工具）、lib/index.js（插件端）。lib 不依赖 tools。
import { createHash } from "node:crypto";
import { sign, verify, createPrivateKey, createPublicKey } from "node:crypto";

// ── 受信发布公钥表（export-pubkey 自动复写；勿手改） ──────────────
// keyId → raw 32B 公钥（base64url）
export const trustedReleaseKeys = {
  "dsh-release-2026": "8mxoxGDHb4gaiLM1Lz-sIknhrdoN0tHadKXQmKIcCVc",
};

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

// ── Ed25519（Node crypto） ───────────────────────────────────────
export const b64u = (buf) => Buffer.from(buf).toString("base64url");
export const fromB64u = (s) => Buffer.from(s, "base64url");
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
// 仅供密钥生成/导出使用（发布工具）
export function rawKeysFromKeyPair(pair) {
  const { publicKey, privateKey } = pair;
  return {
    publicKey: b64u(rawPubFromSpki(publicKey.export({ type: "spki", format: "der" }))),
    privateKey: b64u(rawSeedFromPkcs8(privateKey.export({ type: "pkcs8", format: "der" }))),
  };
}

// ── manifest 验签 ──────────────────────────────────────────────────
/** 要求至少一个签名项 keyId 命中受信公钥且验签通过；返回命中 keyId，失败返回 null。 */
export function verifyManifestSignatures(manifestWithoutSigs, signatures, trustedKeys) {
  // trustedKeys: Map<keyId, rawPubB64u>（或 plain object）
  const getPub = trustedKeys instanceof Map
    ? (k) => trustedKeys.get(k)
    : (k) => trustedKeys?.[k];
  const payload = jcs(manifestWithoutSigs);
  for (const s of signatures ?? []) {
    const pub = getPub(s?.keyId);
    if (!pub) continue;
    try {
      if (edVerify(payload, fromB64u(s.signature), pub)) return s.keyId;
    } catch { /* 该签名项非法，继续尝试其它 */ }
  }
  return null;
}

/** payloadDigest：SHA-256(JCS(剔除 signatures 后) UTF-8) 的 hex —— 与 M1 App 端定义一致。 */
export function manifestPayloadDigest(manifestWithoutSigs) {
  return createHash("sha256").update(jcs(manifestWithoutSigs), "utf8").digest("hex");
}
