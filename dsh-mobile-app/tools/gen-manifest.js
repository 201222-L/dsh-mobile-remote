#!/usr/bin/env node
// 生成 App 自动更新主机源的 manifest.json（package-release.sh 与 package-release.ps1 共用，
// 保证双端产出等价）：JSON.stringify 保证合法（notes 含引号/反斜杠自动转义）、UTF-8 无 BOM、
// notes 取 CHANGELOG 最新条目全文、sha256 小写 hex、size 为 APK 字节数。
//
// 用法：node gen-manifest.js --apk <DSH-Remote-vX.Y.Z.apk> --version <X.Y.Z+BUILD> \
//         --changelog <CHANGELOG.md> --out <manifest.json>
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

function arg(name) {
	const i = process.argv.indexOf(`--${name}`);
	if (i === -1 || i + 1 >= process.argv.length) return "";
	return process.argv[i + 1];
}

const apk = arg("apk");
const version = arg("version");
const changelog = arg("changelog");
const out = arg("out");
if (!apk || !version || !out) {
	console.error("Usage: node gen-manifest.js --apk <file> --version <X.Y.Z+BUILD> --changelog <file> --out <file>");
	process.exit(1);
}
if (!fs.existsSync(apk)) {
	console.error(`APK not found: ${apk}`);
	process.exit(1);
}

// CHANGELOG 最新条目全文：从第一个 `## ` 标题到下一个 `## `（或 EOF），去尾部空行。
// 无 CHANGELOG / 无条目时缺省 notes（manifest 契约中 notes 可选）。
let notes = "";
try {
	const text = fs.readFileSync(changelog, "utf8");
	const lines = text.split(/\r?\n/);
	const start = lines.findIndex((l) => l.startsWith("## "));
	if (start !== -1) {
		let end = lines.findIndex((l, i) => i > start && l.startsWith("## "));
		if (end === -1) end = lines.length;
		while (end > start && lines[end - 1].trim() === "") end--;
		notes = lines.slice(start, end).join("\n").trim();
	}
} catch {
	console.error(`CHANGELOG not found or unreadable: ${changelog}`);
	process.exit(1);
}
if (!notes) {
	console.error("CHANGELOG has no release entry (expected a ## heading)");
	process.exit(1);
}

const buf = fs.readFileSync(apk);
const manifest = {
	version,
	apk: path.basename(apk),
	size: buf.length,
	sha256: crypto.createHash("sha256").update(buf).digest("hex"),
	...(notes ? { notes } : {}),
};

// UTF-8 无 BOM（Windows PowerShell 5.x 的 Set-Content -Encoding UTF8 会带 BOM，Node JSON.parse 抛错）
fs.writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n", "utf8");
console.log(`Manifest: ${out}`);
console.log(fs.readFileSync(out, "utf8"));
