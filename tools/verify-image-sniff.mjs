// 从 lib/index.js 提取真实的 sniffImageType 并做单元验证
import fs from "node:fs";

const src = fs.readFileSync(new URL("../lib/index.js", import.meta.url), "utf8");
const m = src.match(/function sniffImageType\(data\) \{[\s\S]*?\n\}/);
if (!m) { console.error("FAIL: cannot extract sniffImageType"); process.exit(1); }
const sniff = new Function("return (" + m[0] + ")")();

const cases = [
  ["PNG 字节/声明 image/jpeg（微信式误标）", Buffer.from([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,1,2,3,4]), "image/jpeg", "image/png"],
  ["JPEG 字节", Buffer.from([0xFF,0xD8,0xFF,0xE0,0,1,2,3,4,5,6,7]), "image/jpeg", "image/jpeg"],
  ["WebP 字节/声明 image/jpg（典型微信保存图）", Buffer.concat([Buffer.from("RIFF"), Buffer.from([0,0,0,0]), Buffer.from("WEBP"), Buffer.from([1,2,3,4])]), "image/jpg", "image/webp"],
  ["GIF 字节", Buffer.from("GIF89aabcdefgh"), "image/gif", "image/gif"],
  ["HEIC 字节", Buffer.concat([Buffer.from([0,0,0,0x18]), Buffer.from("ftypheic"), Buffer.from("mif1")]), "image/png", "image/heic"],
  ["随机字节（应 null，交内核裁决）", Buffer.from("hello world, this is not an image at all!!"), "image/png", null],
];

let fail = 0;
for (const [name, bytes, declared, expect] of cases) {
  const b64 = bytes.toString("base64");
  const got = sniff(b64);
  const real = got && got !== declared ? got : (got ?? declared);
  const pass = got === expect;
  if (!pass) fail++;
  console.log(`${pass ? "PASS" : "FAIL"}  ${name} → sniff=${got} (期望 ${expect}) ${got !== declared && got ? `→ 纠正为 ${got}` : ""}`);
}
// 模拟 /send 纠正逻辑（与 lib/index.js 中同款）
const declared = "image/jpeg";
const real = sniff(cases[0][1].toString("base64"));
console.log("\n=== /send 纠正逻辑 ===");
console.log(`声明 ${declared} + PNG 字节 → ${real && real !== declared ? "纠正为 " + real : "保持原样"}`);
process.exit(fail ? 1 : 0);
