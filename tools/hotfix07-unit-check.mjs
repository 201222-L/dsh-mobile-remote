// 热修 07 服务端单测：blocksToText 占位开关 / user 摘要不掺占位（手打 [图片] 保留）/ receiptExpired TTL 边界。
// 从已安装 profile 副本导入（仓库根 node_modules 无 @deepseek-ai 依赖）；可用 DSH_MOBILE_PLUGIN 指定模块路径。
import { pathToFileURL } from "node:url";

const candidates = [
  process.env.DSH_MOBILE_PLUGIN,
  "C:/Users/30623/.dsh/profiles/desktop/node_modules/dsh-mobile-remote/lib/index.js",
  "C:/Users/30623/.dsh/profiles/web/node_modules/dsh-mobile-remote/lib/index.js",
  new URL("../lib/index.js", import.meta.url).pathname,
].filter(Boolean).map((p) => (/^[a-zA-Z]:[\\/]/.test(p) ? pathToFileURL(p).href : p));

let mod = null;
for (const p of candidates) {
  try {
    mod = await import(p);
    if (mod) break;
  } catch {
    // 尝试下一个候选
  }
}
if (!mod) {
  console.error("FAIL: 无法导入插件模块（先同步 profile 副本或设 DSH_MOBILE_PLUGIN）");
  process.exit(1);
}
const { blocksToText, receiptExpired, pruneReceiptMap, summarizeEvent } = mod;

let pass = 0;
let fail = 0;
const check = (name, cond, extra = "") => {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name} ${extra}`); }
};

// 1. blocksToText 默认仍出占位（队列预览等其它消费者依赖）
{
  const out = blocksToText([{ type: "text", text: "A" }, { type: "image" }, { type: "text", text: "B" }]);
  check("blocksToText 默认保留 [图片] 占位", out.includes("[图片]"), JSON.stringify(out));
}

// 2. imagePlaceholder:false 不掺占位、文本顺序保留
{
  const out = blocksToText(
    [{ type: "text", text: "A" }, { type: "image" }, { type: "text", text: "B" }],
    { imagePlaceholder: false }
  );
  check("imagePlaceholder:false 无占位", !out.includes("[图片]"), JSON.stringify(out));
  check("文本顺序保留", out === "AB", JSON.stringify(out));
}

// 3. summarizeEvent user/message：无系统占位、手打 [图片] 原文保留、images 元数据照带
{
  const ev = summarizeEvent({
    seq: 1,
    type: "user/message",
    data: {
      id: "m-test-1",
      content: [
        { type: "text", text: "我手打[图片]说明" },
        { type: "image", attachment: { attachmentId: "att-1" } },
        { type: "text", text: "结尾" },
      ],
    },
  });
  check("user 摘要无系统占位行", !ev.data.text.includes("\n[图片]\n"), JSON.stringify(ev.data.text));
  check("用户手打 [图片] 保留", ev.data.text.includes("我手打[图片]说明"), JSON.stringify(ev.data.text));
  check("images 元数据照带", Array.isArray(ev.data.images) && ev.data.images.length === 1, JSON.stringify(ev.data.images));
}

// 4. receiptExpired TTL 边界
{
  const ttl = 15 * 60 * 1000;
  check("TTL 内不过期", receiptExpired(Date.now() - 1, Date.now(), ttl) === false);
  check("恰好在 TTL 边界不过期", receiptExpired(Date.now() - ttl, Date.now(), ttl) === false);
  check("超过 TTL 过期", receiptExpired(Date.now() - ttl - 1, Date.now(), ttl) === true);
  check("默认 TTL 为 15 分钟", receiptExpired(Date.now() - 16 * 60 * 1000, Date.now()) === true);
}

// 5. pruneReceiptMap：未访问的旧回执也会被清理（热修 08）
{
  const ttl = 15 * 60 * 1000;
  const now = Date.now();
  const mk = (at) => ({ status: "done", result: { ok: true }, at });
  const m = new Map([
    ["a", mk(now - 1)],                          // 新
    ["b", mk(now - ttl)],                        // 恰好边界 → 保留
    ["c", mk(now - ttl - 1)],                    // 超时 → 清除
    ["d", mk(now - 16 * 60 * 1000)],             // 旧 → 清除
  ]);
  const changed = pruneReceiptMap(m, now, ttl);
  check("全量清理：过期已删、边界保留", !m.has("c") && !m.has("d") && m.has("a") && m.has("b"), `剩余 ${[...m.keys()].join(",")}`);
  check("有删除时返回 true", changed === true);
  check("无过期时返回 false", pruneReceiptMap(m, now, ttl) === false);
  const cap = new Map();
  for (let i = 0; i < 5; i++) cap.set(`k${i}`, mk(now - i * 1000));
  pruneReceiptMap(cap, now, ttl, 3);
  check("上限裁剪到 max", cap.size === 3, `size=${cap.size}`);
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
