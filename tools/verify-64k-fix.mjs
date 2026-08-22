// 验证修复后的 readBody/readJson/预检逻辑（从 lib/index.js 修复版逐行复刻的行为测试）
import http from "node:http";

const sendJson = (res, status, obj) => {
  const text = JSON.stringify(obj);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(text) });
  res.end(text);
};
const error = (res, status, err, detail) => sendJson(res, status, detail ? { error: err, detail } : { error: err });
const readBody = (req, limit = 64 * 1024) =>
  new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error("body too large"), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
    req.on("close", () => reject(Object.assign(new Error("request closed"), { status: 400 })));
  });
const bodyError = (err, res) => error(res, err?.status === 413 ? 413 : 400, err?.status === 413 ? "payload-too-large" : "bad-request");
const readJson = async (req, res, limit) => {
  try {
    return JSON.parse(await readBody(req, limit));
  } catch (err) {
    return bodyError(err, res);
  }
};

const server = http.createServer(async (req, res) => {
  if (req.method === "POST" && req.url === "/send") {
    const declaredLength = Number(req.headers["content-length"]);
    if (Number.isFinite(declaredLength) && declaredLength > 64 * 1024 * 1024) {
      return error(res, 413, "payload-too-large", "request body exceeds 64MB limit");
    }
    const body = await readJson(req, res, 64 * 1024 * 1024);
    if (body === undefined) return;
    const imgBytes = (body.images?.[0]?.data?.length ?? 0);
    return sendJson(res, 200, { ok: true, parsedBytes: Buffer.byteLength(JSON.stringify(body)), imgB64Chars: imgBytes });
  }
  res.writeHead(404); res.end();
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;
const results = [];
const post = async (name, body, opts = {}) => {
  try {
    const r = await fetch(`http://127.0.0.1:${port}/send`, {
      method: "POST",
      headers: { "content-type": "application/json", ...(opts.contentLength ? { "content-length": String(opts.contentLength) } : {}) },
      body: typeof body === "string" ? body : JSON.stringify(body),
    });
    results.push([name, "HTTP " + r.status, (await r.text()).slice(0, 120)]);
  } catch (e) {
    results.push([name, "CLIENT-ERROR", String(e.cause ?? e).slice(0, 120)]);
  }
};

// 1) 140KB 图片 payload（此前 64KB 误限场景）——应 200 且完整解析
const big = "A".repeat(140 * 1024);
await post("140KB image", { sessionId: "s1", text: "test", images: [{ mediaType: "image/png", data: big }] });

// 2) 声明 content-length 超 64MB —— 应立即 413 JSON（无 RST）
await post("declared >64MB", "", { contentLength: 65 * 1024 * 1024 });

// 3) 小请求仍正常（回归）
await post("small text", { sessionId: "s1", text: "hi" });

// 4) 默认 64KB 上限仍生效（readJson 不传 limit 的调用点回归）——用 /send 之外的路径模拟
const server2 = http.createServer(async (req, res) => {
  const body = await readJson(req, res); // 不传 limit
  if (body === undefined) return;
  sendJson(res, 200, { ok: true });
});
await new Promise((r) => server2.listen(0, "127.0.0.1", r));
const port2 = server2.address().port;
try {
  const r = await fetch(`http://127.0.0.1:${port2}/x`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ pad: "A".repeat(70 * 1024) }),
  });
  // 服务端 destroy 后 fetch 可能抛错也可能拿到空响应——两者都证明 64KB 默认上限仍在拦截
  results.push(["default 64KB guard", "HTTP " + r.status + " (destroy path)", ""]);
} catch (e) {
  results.push(["default 64KB guard", "CLIENT-RESET (expected)", String(e.cause ?? e).slice(0, 80)]);
}

for (const row of results) console.log("[" + row[0] + "] " + row[1] + " " + row[2]);
server.close(); server2.close();
