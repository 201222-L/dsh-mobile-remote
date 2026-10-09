#!/usr/bin/env node
// 校验发布产物 dist/manifest.json（spec「副 seam」建议项，对应 package-release.sh/ps1 的产出）：
//   1. JSON 可解析；2. version 精确到 build（X.Y.Z+N）；3. apk 文件存在于同目录；
//   4. size 与 APK 实际字节数一致；5. sha256 与 APK 实算一致；6. notes 非空。
// 用法：node tools/verify-update-manifest.mjs [dist目录]（默认 dsh-mobile-app/dist）
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const dir = process.argv[2]
	? path.resolve(process.argv[2])
	: path.resolve(new URL("../dist", import.meta.url).pathname);
const manifestPath = path.join(dir, "manifest.json");

let fail = 0;
function check(name, pass, detail = "") {
	if (!pass) fail++;
	console.log(`${pass ? "PASS" : "FAIL"}  ${name}${detail ? ` (${detail})` : ""}`);
}

let m = null;
try {
	m = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
	check("manifest.json 可解析", true);
} catch (e) {
	check(`manifest.json 可解析（${manifestPath}）`, false, String(e));
	console.log("\nRESULT: FAIL");
	process.exit(1);
}

check("version 精确到 build（X.Y.Z+N）", /^\d+\.\d+\.\d+\+\d+$/.test(m.version ?? ""), `version=${m.version}`);
check("apk 文件存在", typeof m.apk === "string" && m.apk !== "" && fs.existsSync(path.join(dir, m.apk ?? "")), `apk=${m.apk}`);

if (typeof m.apk === "string" && fs.existsSync(path.join(dir, m.apk))) {
	const buf = fs.readFileSync(path.join(dir, m.apk));
	check("size 与 APK 字节数一致", m.size === buf.length, `manifest=${m.size} 实际=${buf.length}`);
	const hash = crypto.createHash("sha256").update(buf).digest("hex");
	check("sha256 与 APK 实算一致", m.sha256 === hash, `manifest=${m.sha256} 实际=${hash}`);
} else {
	check("size 与 APK 字节数一致", false, "apk 缺失跳过");
	check("sha256 与 APK 实算一致", false, "apk 缺失跳过");
}

check("notes 非空", typeof m.notes === "string" && m.notes.trim() !== "");

console.log(`\nRESULT: ${fail === 0 ? "PASS" : "FAIL"}`);
process.exit(fail === 0 ? 0 : 1);
