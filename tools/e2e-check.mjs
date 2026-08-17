// SSE 事件转发验证：连上后发消息，观察所有帧类型
const T = process.env.DSH_MOBILE_TOKEN;
const base = process.env.DSH_MOBILE_BASE ?? "http://127.0.0.1:3080/m";

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
const sid = boot.agents?.[0]?.id;
if (!sid) {
  console.log("send => skipped（实例无运行中 agent）");
} else {
  const r = await fetch(base + "/api/send", {
    method: "POST",
    headers: { "content-type": "application/json", "x-mobile-token": T },
    body: JSON.stringify({ sessionId: sid, text: "（dsh-mobile-remote 第二轮自检消息，请忽略。）" }),
  });
  console.log("send =>", r.status);
}

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

// ── v2.6.0 安全：登录限流 ──
// 阈值内（9 次错误）不封锁、正确口令可用；随后连续错误应触发 429。
// 注意：封锁后本机 IP 60s 内会被 429，此段必须放在脚本最后。
if (T) {
  const bad = "wrong-token-rate-limit-test";
  for (let i = 0; i < 9; i++) {
    await fetch(base + "/api/bootstrap", { headers: { "x-mobile-token": bad } });
  }
  const ok = await fetch(base + "/api/bootstrap", { headers: { "x-mobile-token": T } });
  console.log("rate-limit(阈值内) =>", ok.status === 200 ? "OK" : "FAIL " + ok.status);
  let blocked = false;
  for (let i = 0; i < 15; i++) {
    const r = await fetch(base + "/api/bootstrap", { headers: { "x-mobile-token": bad } });
    if (r.status === 429) {
      blocked = true;
      break;
    }
  }
  console.log("rate-limit(封锁) =>", blocked ? "429 OK" : "未触发（认证未启用或阈值未命中）");
}
