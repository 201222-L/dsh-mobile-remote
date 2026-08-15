// Phase 1 API 验证：catalog / session-config / sessions / notifications / actions + 旧端点回归
const T = process.env.DSH_MOBILE_TOKEN;
const base = "http://127.0.0.1:56343/m";
const h = { "content-type": "application/json", "x-mobile-token": T };

const j = async (r) => ({ status: r.status, body: await r.json().catch(() => null) });
const show = (name, r) => console.log(`${name} => ${r.status}`, JSON.stringify(r.body).slice(0, 240));

// 1. 页面
const page = await fetch(base + "/");
console.log("GET /m =>", page.status, (await page.text()).slice(0, 40));

// 2. catalog（新）
show("catalog", await j(await fetch(base + "/api/catalog", { headers: h })));

// 3. 现有会话的 session-config（新）
const boot = (await j(await fetch(base + "/api/bootstrap", { headers: h }))).body;
const sid = boot?.agents?.[0]?.id ?? boot?.sessions?.[0]?.id;
console.log("active session:", sid);
show("session-config GET", await j(await fetch(base + "/api/session-config?sessionId=" + sid, { headers: h })));

// 4. 切换模型到 pro + 推理 high（新，写）
show("session-config POST pro/high",
  await j(await fetch(base + "/api/session-config", { method: "POST", headers: h, body: JSON.stringify({ sessionId: sid, provider: "deepseek-official", model: "deepseek-v4-pro", reasoningEffort: "high" }) })));

// 5. 切回 flash + max（还原）
show("session-config POST restore flash/max",
  await j(await fetch(base + "/api/session-config", { method: "POST", headers: h, body: JSON.stringify({ sessionId: sid, provider: "deepseek-official", model: "deepseek-v4-flash", reasoningEffort: "max" }) })));

// 6. 权限：read-only 切换 + 还原（新）
show("session-config POST perm=read-only",
  await j(await fetch(base + "/api/session-config", { method: "POST", headers: h, body: JSON.stringify({ sessionId: sid, permissionPreset: "read-only" }) })));
show("session-config POST perm=workspace-write restore",
  await j(await fetch(base + "/api/session-config", { method: "POST", headers: h, body: JSON.stringify({ sessionId: sid, permissionPreset: "workspace-write" }) })));

// 7. danger 无确认 -> 应 400
show("session-config POST danger no-confirm",
  await j(await fetch(base + "/api/session-config", { method: "POST", headers: h, body: JSON.stringify({ sessionId: sid, permissionPreset: "danger-full-access" }) })));

// 8. 新建会话（新）
const created = await j(await fetch(base + "/api/sessions", { method: "POST", headers: h, body: JSON.stringify({ preset: "standard", model: "deepseek-v4-flash", reasoningEffort: "max", permissionPreset: "workspace-write" }) }));
show("sessions POST", created);
const newSid = created.body?.sessionId;
if (newSid) {
  show("send to new session", await j(await fetch(base + "/api/send", { method: "POST", headers: h, body: JSON.stringify({ sessionId: newSid, text: "（Phase 1 验证：新建会话可用性自检）" }) })));
}

// 9. 通知（新）
show("notifications", await j(await fetch(base + "/api/notifications", { headers: h })));

// 10. 动作（新）
show("actions", await j(await fetch(base + "/api/actions", { headers: h })));
