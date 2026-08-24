// v3.0.0 热修 05 服务端自检：requestId 幂等回执 + 64MB 传输上限
// 用法：
//   DSH_MOBILE_TOKEN=<口令> node tools/hotfix05-check.mjs          # 仅无投递用例（安全）
//   DSH_MOBILE_TOKEN=<口令> DSH_MOBILE_LIVE=1 node tools/hotfix05-check.mjs  # 含 2 次真实投递
// 前置：DSH 已重启并加载热修 05 插件（旧插件无 requestId 语义，断言会失败）。
// LIVE 用例会向 bootstrap 的首个 agent 各投递一条消息（文本 1 次 + 图片 1 次），
// 用于验证「同 requestId 重试返回第一次结果、不二次投递」；会真实触发 agent 处理，谨慎使用。
const T = process.env.DSH_MOBILE_TOKEN;
const base = process.env.DSH_MOBILE_BASE ?? "http://127.0.0.1:3080/m";
const LIVE = process.env.DSH_MOBILE_LIVE === "1";
const H = { "content-type": "application/json", ...(T ? { "x-mobile-token": T } : {}) };
const { request } = await import("node:http");

let pass = 0;
let fail = 0;
const check = (name, cond, extra = "") => {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name} ${extra}`); }
};

const j = async (r) => { try { return await r.json(); } catch { return null; } };
const rid = () => crypto.randomUUID();

// ── 1. 非法 requestId → 400 ──
{
  const r = await fetch(base + "/api/send", {
    method: "POST", headers: H,
    body: JSON.stringify({ sessionId: "session-bogus", text: "t", requestId: "bad id!" }),
  });
  check("非法 requestId 拒绝(400)", r.status === 400, `got ${r.status}`);
}

// ── 2. 随机 requestId 回执查询 → 404 ──
{
  const r = await fetch(base + `/api/send-receipt?sessionId=session-bogus&requestId=${rid()}`, { headers: H });
  const d = await j(r);
  check("未命中回执 404 receipt-not-found", r.status === 404 && d?.error === "receipt-not-found", `got ${r.status} ${JSON.stringify(d)}`);
}

// ── 3. 空 requestId 参数 → 400 ──
{
  const r = await fetch(base + "/api/send-receipt?sessionId=session-bogus", { headers: H });
  check("缺 requestId 400", r.status === 400, `got ${r.status}`);
}

// ── 4. 超 64MB 声明 → 413（仅发头不发体，服务端预检即拒） ──
await new Promise((resolve) => {
  const url = new URL(base + "/api/send");
  const req = request({ hostname: url.hostname, port: url.port, path: url.pathname, method: "POST",
    headers: { ...H, "content-length": String(70 * 1024 * 1024) } }, (res) => {
    let buf = "";
    res.on("data", (c) => (buf += c));
    res.on("end", () => {
      check("超限预检 413 payload-too-large", res.statusCode === 413 && buf.includes("payload-too-large"), `got ${res.statusCode} ${buf}`);
      resolve();
    });
  });
  req.on("error", () => resolve());
  req.end('{"sessionId":"x"}'); // 短体 + 假 content-length：服务端应先于读体回 413
});

// ── 5~7. 幂等回执（LIVE，真实投递） ──
if (!LIVE) {
  console.log("(跳过 LIVE 用例：设置 DSH_MOBILE_LIVE=1 启用)");
} else {
  const boot = await (await fetch(base + "/api/bootstrap", { headers: H })).json();
  const sid = boot.agents?.[0]?.id;
  if (!sid) {
    console.log("(跳过 LIVE 用例：实例无运行中 agent)");
  } else {
    // 5) 文本发送 + 回执查询 + 同 id 重试幂等
    {
      const id1 = rid();
      const r1 = await fetch(base + "/api/send", {
        method: "POST", headers: H,
        body: JSON.stringify({ sessionId: sid, text: "（热修 05 幂等自检，请忽略。）", requestId: id1 }),
      });
      const d1 = await j(r1);
      check("文本发送 200", r1.status === 200, `got ${r1.status} ${JSON.stringify(d1)}`);
      const m1 = d1?.messageId;
      const rr = await fetch(base + `/api/send-receipt?sessionId=${sid}&requestId=${id1}`, { headers: H });
      const dr = await j(rr);
      check("回执 done 且 messageId 一致", rr.status === 200 && dr?.receipt?.status === "done" && dr?.receipt?.result?.messageId === m1, JSON.stringify(dr));
      const r2 = await fetch(base + "/api/send", {
        method: "POST", headers: H,
        body: JSON.stringify({ sessionId: sid, text: "（热修 05 幂等自检，请忽略。）", requestId: id1 }),
      });
      const d2 = await j(r2);
      check("同 requestId 重试返回第一次结果（不二次投递）", r2.status === 200 && d2?.messageId === m1, JSON.stringify(d2));
    }
    // 6) 空文本图片发送 + 同 id 重试幂等（1×1 PNG）
    {
      const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
      const id2 = rid();
      const body = { sessionId: sid, text: "", images: [{ mediaType: "image/png", data: png }], requestId: id2 };
      const r1 = await fetch(base + "/api/send", { method: "POST", headers: H, body: JSON.stringify(body) });
      const d1 = await j(r1);
      check("空文本图片发送 accepted", r1.status === 200 && d1?.accepted === true, `got ${r1.status} ${JSON.stringify(d1)}`);
      const r2 = await fetch(base + "/api/send", { method: "POST", headers: H, body: JSON.stringify(body) });
      const d2 = await j(r2);
      check("图片同 id 重试幂等（结果一致）", r2.status === 200 && JSON.stringify(d1) === JSON.stringify(d2), JSON.stringify(d2));
      const rr = await fetch(base + `/api/send-receipt?sessionId=${sid}&requestId=${id2}`, { headers: H });
      const dr = await j(rr);
      check("图片回执 done", rr.status === 200 && dr?.receipt?.status === "done", JSON.stringify(dr));
    }
  }
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
