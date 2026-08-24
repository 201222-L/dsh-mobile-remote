// M2 电脑源凭据：updateToken（与全局 authToken 完全隔离）。
// 生成：24 随机字节 base64url，存 ~/.dsh/mobile-remote/update-token.json（0600）。
// 轮换：rotateUpdateToken() 生成新值（旧值立即失效）——App 侧提示重新扫码配对（不由本模块自动重取）。
// 认证：HMAC-SHA256 抗重放（canonical 请求串 + ±60s + nonce 按 token 分区去重）。
import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";

const TOKEN_FILE = join(homedir(), ".dsh", "mobile-remote", "update-token.json");
const MSG_TTL = 60 * 1000; // ±60s 时间窗
const NONCE_MAX = 4096;
const NONCE_TTL = 5 * 60 * 1000;

function loadOrCreateToken() {
  try {
    const doc = JSON.parse(readFileSync(TOKEN_FILE, "utf8"));
    if (typeof doc?.token === "string" && doc.token.length >= 32) return doc.token;
  } catch { /* 无/损坏 → 新建 */ }
  const token = randomBytes(24).toString("base64url");
  mkdirSync(dirname(TOKEN_FILE), { recursive: true });
  writeFileSync(TOKEN_FILE, JSON.stringify({ token, createdAt: new Date().toISOString() }, null, 2) + "\n", { mode: 0o600 });
  return token;
}

export function getUpdateToken() {
  return loadOrCreateToken();
}

/** 轮换：生成新 token（旧值立即失效）。App 将收到 401 → 提示重新扫码配对。 */
export function rotateUpdateToken() {
  const token = loadOrCreateToken(); // 确保目录存在
  const next = randomBytes(24).toString("base64url");
  writeFileSync(TOKEN_FILE, JSON.stringify({ token: next, createdAt: new Date().toISOString(), rotatedFrom: token.slice(0, 8) }, null, 2) + "\n", { mode: 0o600 });
  return next;
}

function b64uDecode(s) {
  try {
    let t = String(s).replaceAll("-", "+").replaceAll("_", "/");
    switch (t.length % 4) {
      case 2: t += "=="; break;
      case 3: t += "="; break;
    }
    return Buffer.from(t, "base64");
  } catch {
    return null;
  }
}

/** canonicalRequest = method\npath\ncanonicalQuery\nhexBodySha256\nts\nnonce */
export function canonicalRequest({ method = "GET", path = "", query = {}, hexBodySha256 = "", ts = "", nonce = "" }) {
  const canonicalQuery = Object.keys(query)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(String(query[k]))}`)
    .join("&");
  const q = canonicalQuery === "" ? "" : canonicalQuery;
  return [method, path, q, hexBodySha256, String(ts), String(nonce)].join("\n");
}

export function hmacValue(token, canonical) {
  return createHmac("sha256", token).update(canonical, "utf8").digest();
}

export function safeEqual(a, b) {
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/** nonce 缓存（按 token 分区，容量 4096，5 分钟过期） */
export class NonceCache {
  constructor() {
    this.byToken = new Map(); // token -> Map<nonce, expireAt>
  }
  remember(token, nonce) {
    if (nonce.length < 16) return false;
    let m = this.byToken.get(token);
    if (!m) {
      m = new Map();
      this.byToken.set(token, m);
    }
    if (m.has(nonce)) return false; // 重放
    m.set(nonce, Date.now() + NONCE_TTL);
    this._prune(token, m); // 先 add 后 prune：prune 的空 map 删除不得发生在创建时
    return true;
  }
  _prune(token, m) {
    if (m.size > NONCE_MAX) {
      const first = m.keys().next().value;
      m.delete(first);
    }
    const now = Date.now();
    for (const [k, exp] of m) {
      if (exp < now) m.delete(k);
    }
    if (m.size === 0) this.byToken.delete(token);
  }
}

/** 校验 updateToken 请求头（x-update-ts/x-update-nonce/x-update-auth）。
 *  返回 { ok, reason }。updateToken 由调用方注入（与全局 authToken 隔离）。 */
export function verifyUpdateAuth({ headers, method, path, query = {}, bodyShaHex = "", token, nonceCache }) {
  const ts = headers["x-update-ts"];
  const nonce = headers["x-update-nonce"];
  const auth = headers["x-update-auth"];
  if (typeof ts !== "string" || typeof nonce !== "string" || typeof auth !== "string" || auth === "") {
    return { ok: false, reason: "missing-headers" };
  }
  const now = Date.now();
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum) || Math.abs(now - tsNum * 1000) > MSG_TTL) {
    return { ok: false, reason: "stale-timestamp" };
  }
  if (Buffer.from(nonce, "hex").length < 16) {
    return { ok: false, reason: "short-nonce" };
  }
  if (!nonceCache.remember(token, nonce)) {
    return { ok: false, reason: "nonce-replay" };
  }
  const canonical = canonicalRequest({ method, path, query, hexBodySha256: bodyShaHex, ts, nonce });
  const expect = hmacValue(token, canonical);
  const got = b64uDecode(auth);
  if (!got || !safeEqual(expect, got)) {
    return { ok: false, reason: "bad-signature" };
  }
  return { ok: true, reason: null };
}
