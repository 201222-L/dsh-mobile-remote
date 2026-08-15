// 双通道推送最终验证：发消息 → turn 完成 → 微信 + ntfy 同时推送
const T = process.env.DSH_MOBILE_TOKEN;
const base = "http://127.0.0.1:3080/m";
const h = { "x-mobile-token": T, "content-type": "application/json" };

const boot = await (await fetch(base + "/api/bootstrap", { headers: h })).json();
const sid = boot.agents[0].id;
console.log("target session:", sid);
const r = await fetch(base + "/api/send", {
  method: "POST",
  headers: h,
  body: JSON.stringify({ sessionId: sid, text: "（双通道推送最终验证：请只回复“推送 OK”三个字，然后停住，不要执行任何其他操作。）" }),
});
console.log("send =>", r.status, JSON.stringify(await r.json()));
