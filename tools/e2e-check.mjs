// SSE 事件转发验证：连上后发消息，观察所有帧类型
const T = process.env.DSH_MOBILE_TOKEN;
const base = "http://127.0.0.1:3080/m";

const ac = new AbortController();
setTimeout(() => ac.abort(), 25000);
const es = await fetch(base + "/api/events", { headers: { "x-mobile-token": T }, signal: ac.signal });
const reader = es.body.getReader();
const dec = new TextDecoder();
let buf = "";
const types = new Set();
const frames = [];

// 连上后等 1.5s 收 hello，再发消息
await new Promise((r) => setTimeout(r, 1500));
const boot = await (await fetch(base + "/api/bootstrap", { headers: { "x-mobile-token": T } })).json();
const sid = boot.agents[0].id;
const r = await fetch(base + "/api/send", {
  method: "POST",
  headers: { "content-type": "application/json", "x-mobile-token": T },
  body: JSON.stringify({ sessionId: sid, text: "（dsh-mobile-remote 第二轮自检消息，请忽略。）" }),
});
console.log("send =>", r.status);

const deadline = Date.now() + 23000;
while (Date.now() < deadline) {
  let chunk;
  try {
    chunk = await reader.read();
  } catch {
    break; // AbortError：时间到
  }
  const { done, value } = chunk;
  if (done) break;
  buf += dec.decode(value, { stream: true });
  let idx;
  while ((idx = buf.indexOf("\n\n")) >= 0) {
    const frame = buf.slice(0, idx);
    buf = buf.slice(idx + 2);
    if (!frame.startsWith("data: ")) continue;
    const f = JSON.parse(frame.slice(6));
    if (f.type === "hello") { frames.push("hello"); continue; }
    if (f.type === "agent/status") { frames.push("agent/status:" + f.status); continue; }
    if (f.type === "session/event") {
      frames.push("event:" + f.event.type + (f.event.data?.turn !== undefined ? "#" + f.event.data.turn : ""));
      types.add(f.event.type);
    }
  }
}
console.log("frames:", frames.slice(0, 30).join(" | ") || "(none)");
console.log("event types:", [...types].join(", ") || "(none)");
