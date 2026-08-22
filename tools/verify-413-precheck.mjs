// 单独验证 content-length 预检：声明 65MB → 服务器应立即回 413 JSON 而不读 body
import http from "node:http";

const sendJson = (res, status, obj) => {
  const text = JSON.stringify(obj);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "content-length": Buffer.byteLength(text) });
  res.end(text);
};
const error = (res, status, err, detail) => sendJson(res, status, detail ? { error: err, detail } : { error: err });

const server = http.createServer((req, res) => {
  const declaredLength = Number(req.headers["content-length"]);
  if (Number.isFinite(declaredLength) && declaredLength > 64 * 1024 * 1024) {
    return error(res, 413, "payload-too-large", "request body exceeds 64MB limit");
  }
  sendJson(res, 200, { ok: true });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const result = await new Promise((resolve) => {
  const req = http.request({ host: "127.0.0.1", port, path: "/send", method: "POST", headers: { "content-type": "application/json", "content-length": String(65 * 1024 * 1024) } }, (res) => {
    let buf = "";
    res.on("data", (c) => (buf += c));
    res.on("end", () => resolve(`HTTP ${res.statusCode} BODY ${buf.slice(0, 140)}`));
  });
  req.on("error", (e) => resolve("CLIENT-ERROR " + e.message));
  req.write('{"x":1}'); // 只发一点点，服务器应已回 413
  req.end();
});
console.log("[declared >64MB precheck] " + result);
server.close();
