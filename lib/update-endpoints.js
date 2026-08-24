// M2 电脑源/插件联动端点逻辑（/m/api/update-* 与 /plugin-update）。
// 信任链：插件内置公钥独立验签 manifest → source 受限 → 按已验签 manifest 取产物（sha256/size 校验）→ 暂存。
// 注意：调用方传入的 URL/hash 一律不作为信任输入；artifactId 白名单来自当前已验签 manifest。
import { createHash } from "node:crypto";
import { createWriteStream, createReadStream, readFileSync, writeFileSync, mkdirSync, existsSync, copyFileSync, statSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { verifyManifestSignatures, manifestPayloadDigest, trustedReleaseKeys } from "./update-crypto.js";
import { verifyUpdateAuth, getUpdateToken, NonceCache } from "./update-token.js";

const UPDATES_DIR = join(homedir(), ".dsh", "mobile-remote", "updates");
const GITHUB_OWNER = "201222-L";
const GITHUB_REPO = "dsh-mobile-remote";
const SOURCES = new Set(["github", "local-cache"]);
// review P1-3：/update-file 只暴露设计裁定的两个固定 artifactId（最小暴露面）
const ALLOWED_ARTIFACT_IDS = new Set(["dsh-remote-apk", "dsh-remote-plugin"]);
/** fileName 必须为纯文件名：拒绝路径分隔符、`.`、`..`、NUL 等路径成分 */
function isSafeFileName(name) {
  if (typeof name !== "string" || name.length === 0) return false;
  if (name === "." || name === "..") return false;
  if (name.includes("/") || name.includes("\\")) return false;
  if (name.includes("\0")) return false;
  return true;
}

/** 端点共享状态（apply 作用域创建） */
export class UpdateState {
  constructor() {
    this.updatesDir = UPDATES_DIR;
    this.nonceCache = new NonceCache();
    this.verified = null; // { manifest, digest, artifactMap: Map<artifactId, {fileName,sizeBytes,sha256,versionName}> }
  }
  token() {
    return getUpdateToken();
  }
  rememberVerified(manifest, digest) {
    const artifactMap = new Map();
    for (const [kind, art] of Object.entries(manifest.artifacts ?? {})) {
      if (art && art.artifactId && art.fileName) {
        artifactMap.set(art.artifactId, {
          fileName: art.fileName,
          sizeBytes: Number(art.sizeBytes) || 0,
          sha256: art.sha256,
          versionName: art.versionName,
        });
      }
    }
    this.verified = { manifest, digest, artifactMap };
  }
}

export function updateEndpointPath(rest) {
  // 仅更新端点走 updateToken 认证（先于全局 authToken 分流）
  if (rest === "/plugin-update") return "/plugin-update";
  const m = /^\/update-(check|file)\/?$/.exec(rest) ?? /^\/update-file\/([^/]+)$/.exec(rest);
  return m ? rest : null;
}

export function parseUpdateAuthHeaders(headers) {
  return {
    ts: String(headers["x-update-ts"] ?? ""),
    nonce: String(headers["x-update-nonce"] ?? ""),
    auth: String(headers["x-update-auth"] ?? ""),
  };
}

export function verifyUpdateRequest({ headers, method, path, query, bodyShaHex, nonceCache }) {
  return verifyUpdateAuth({
    headers,
    method,
    path,
    query: query ?? {},
    bodyShaHex: bodyShaHex ?? "",
    token: getUpdateToken(),
    nonceCache,
  });
}

/** manifest 扫描与验签（update-check）：updates 目录下 manifest.json / update.json */
export function scanAndVerifyManifest(dir = UPDATES_DIR, trustedKeys = trustedReleaseKeys) {
  for (const name of ["manifest.json", "update.json"]) {
    const p = join(dir, name);
    if (!existsSync(p)) continue;
    const doc = JSON.parse(readFileSync(p, "utf8"));
    const without = { ...doc };
    delete without.signatures;
    const kid = verifyManifestSignatures(without, doc.signatures, trustedKeys);
    if (!kid) throw new Error("manifest 验签失败");
    return { manifest: doc, digest: manifestPayloadDigest(without), verifiedKeyId: kid };
  }
  return null;
}

/** 产物信息（size + sha256）——统一校验用 */
export function fileInfo(p) {
  const buf = readFileSync(p);
  return { size: buf.length, sha256: createHash("sha256").update(buf).digest("hex") };
}

/** 插件暂存（plugin-update）：验签 → declaredAppVersionCode 校验 → source 受限 → 下载/校验 → staged。
 *  幂等：同 manifestDigest 已暂存 → 直接 {staged:true}。 */
export async function stagePluginUpdate({ manifest, source, declaredAppVersionCode, state, fetchImpl = fetch, logger, trustedKeys = trustedReleaseKeys }) {
  if (!SOURCES.has(source)) throw new Error("source 不允许");
  const without = { ...manifest };
  delete without.signatures;
  const kid = verifyManifestSignatures(without, manifest.signatures, trustedKeys);
  if (!kid) throw new Error("manifest 验签失败");
  const digest = manifestPayloadDigest(without);
  const artifact = manifest.artifacts?.plugin;
  if (!artifact?.fileName || !artifact?.sha256) throw new Error("manifest 缺少插件产物信息");
  const minCode = Number(manifest.minAppVersionCode ?? 0);
  const declared = Number(declaredAppVersionCode);
  if (!Number.isInteger(declared) || declared < minCode) {
    const err = new Error(`App 版本 ${declared} 低于目标插件要求 ${minCode}`);
    err.status = 409;
    throw err;
  }
  // 幂等：同 digest 已暂存
  const stageDir = join(state.updatesDir, "staged", String(manifest.sequence));
  const stagedJson = join(stageDir, "staged.json");
  if (existsSync(stagedJson)) {
    try {
      const prev = JSON.parse(readFileSync(stagedJson, "utf8"));
      if (prev.manifestDigest === digest) return { staged: true, again: true };
    } catch { /* 损坏 → 重新暂存 */ }
  }
  // 取包：github → 直连 Release 资产（流式下载+哈希，不整包进内存）；local-cache → 更新目录
  let srcPath = null;
  if (source === "github") {
    const res = await fetchImpl(`https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest`, {
      headers: { accept: "application/vnd.github+json" },
    });
    if (!res.ok) throw new Error("GitHub releases 不可用");
    const release = await res.json();
    const asset = (release.assets ?? []).find((a) => a?.name === artifact.fileName);
    if (!asset?.browser_download_url) throw new Error("Release 未找到插件资产");
    const dl = await fetchImpl(asset.browser_download_url);
    if (!dl.ok) throw new Error(`下载失败 HTTP ${dl.status}`);
    if (!dl.body) throw new Error("下载无响应体");
    mkdirSync(join(stageDir), { recursive: true });
    const outPath = join(stageDir, artifact.fileName);
    const out = createWriteStream(outPath);
    const hash = createHash("sha256");
    for await (const chunk of dl.body) {
      hash.update(chunk);
      out.write(chunk);
    }
    await new Promise((resolve, reject) => {
      out.on("finish", resolve);
      out.on("error", reject);
      out.end();
    });
    const info = { size: statSync(outPath).size, sha256: hash.digest("hex") };
    if (info.sha256 !== artifact.sha256 || info.size !== artifact.sizeBytes) {
      rmSync(outPath, { force: true });
      throw new Error("插件产物校验失败");
    }
    srcPath = outPath;
  } else {
    const local = join(state.updatesDir, artifact.fileName);
    if (!existsSync(local)) throw new Error("local-cache 无插件包");
    const info = fileInfo(local);
    if (info.sha256 !== artifact.sha256 || info.size !== artifact.sizeBytes) throw new Error("local-cache 插件包校验失败");
    mkdirSync(join(stageDir), { recursive: true });
    copyFileSync(local, join(stageDir, artifact.fileName));
    srcPath = join(stageDir, artifact.fileName);
  }
  writeFileSync(
    stagedJson,
    JSON.stringify({
      manifestDigest: digest,
      sequence: manifest.sequence,
      versionName: artifact.versionName ?? "?",
      fileName: artifact.fileName,
      sha256: artifact.sha256,
      sizeBytes: artifact.sizeBytes,
      verifiedKeyId: kid,
      at: new Date().toISOString(),
    }, null, 2) + "\n",
    "utf8",
  );
  // helper 重验签需要 manifest 原文：随 staged 一起持久化
  writeFileSync(join(stageDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n", "utf8");
  if (logger) logger.info(`mobile-remote: 插件已暂存 ${artifact.fileName}（sequence=${manifest.sequence}, 验签=${kid}）`);
  return { staged: true, fileName: artifact.fileName, manifestDigest: digest };
}

/** /update-file 响应（流式转发）；返回 { error }。artifactId 固定白名单 + fileName 纯文件名校验。 */
export async function serveArtifactFile(artifactId, state, res) {
  if (!ALLOWED_ARTIFACT_IDS.has(artifactId)) return { error: "unknown-artifact" };
  const art = state.verified?.artifactMap.get(artifactId);
  if (!art) return { error: "unknown-artifact" };
  if (!isSafeFileName(art.fileName)) return { error: "bad-file-name" };
  const p = join(state.updatesDir, art.fileName);
  if (!existsSync(p)) return { error: "missing-file" };
  const info = fileInfo(p);
  if (Number(art.sizeBytes) > 0 && info.size !== Number(art.sizeBytes)) return { error: "size-mismatch" };
  res.writeHead(200, {
    "content-type": "application/octet-stream",
    "content-length": info.size,
    "x-artifact-sha256": info.sha256,
  });
  await new Promise((resolve) => {
    const stream = createReadStream(p);
    stream.pipe(res);
    stream.on("error", () => { try { res.destroy(); } catch {} resolve(); });
    stream.on("end", () => resolve());
  });
  return { error: null };
}
