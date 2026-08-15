# 03 API 鎺ュ彛璁捐鏂囨。 鈥?dsh-mobile-remote

> 鐗堟湰锛歷2.1锛圓pp 浜у搧鐗堬級 路 鐘舵€侊細宸插疄鐜?路 閰嶅锛?0-寮€鍙戞€荤翰.md銆?2-architecture.md銆?4-security.md
> 鍓嶇紑锛歚/m`锛堝彲閰嶇疆椤?`path`锛岄粯璁?`/m`锛夈€備互涓嬫墍鏈夎矾寰勫潎浠ュ墠缂€寮€澶淬€?> 鏈?API 鍚屾椂鏈嶅姟 Flutter App锛坉sh-mobile-app锛変笌妗岄潰璁剧疆椤靛鎴风妯″潡锛涗笉鍚綉椤电増椤甸潰锛坴2.1 璧风Щ闄わ級銆?
## 1. 閫氱敤绾﹀畾

- **鍐呭绫诲瀷**锛欽SON API 涓€寰?`application/json; charset=utf-8`锛涢敊璇粺涓€ `{ "error": string, "detail"?: string }`銆?- **閴存潈**锛歚authToken` 閰嶇疆涓虹┖ 鈫?鏃犻壌鏉冿紱闈炵┖ 鈫?闄?`GET /m/api/qr-config`锛堜粎 loopback锛夊锛屾墍鏈夌鐐硅姹傚嚟璇併€?- **鍑瘉褰㈠紡**锛堜簩閫変竴锛屼换涓€閫氳繃鍗冲彲锛夛細
  - 璇锋眰澶达細`X-Mobile-Token: <token>`锛圓pp 浣跨敤锛?  - Cookie锛歚dsh_mobile_token=<token>`锛堝吋瀹逛繚鐣欙紝鏃犵櫥褰曞叆鍙ｏ級
- **鏈璇佸搷搴?*锛歚401 { "error": "auth-required", "detail": "璁块棶鍙ｄ护鏈€氳繃楠岃瘉" }`銆?- **璺敱鍖归厤**锛歚/m/api/*` 鎸夊墠缂€娉ㄥ唽锛涙湭鐭ュ瓙璺緞 鈫?`404 { "error": "not-found" }`锛沗/m` 涔嬪鐨勮８璺緞涓嶆嫤鎴紙fallback 浠嶅綊妗岄潰 SPA锛夈€?
## 2. 绔偣鎬昏〃

| 鏂规硶 | 璺緞 | 鐢ㄩ€?| 閴存潈 |
|---|---|---|---|
| GET | `/m/api/bootstrap` | 鍒濆鐘舵€侊細鍦板潃銆佽璇佽姹傘€乤gent 鎽樿銆佷細璇濆垪琛?| 鏄?|
| POST | `/m/api/send` | 鍚戞寚瀹?榛樿 agent 娉ㄥ叆娑堟伅 | 鏄?|
| GET | `/m/api/sessions` | 浼氳瘽鍒楄〃 | 鏄?|
| GET | `/m/api/history` | 鎸囧畾浼氳瘽鐨勪簨浠跺巻鍙诧紙澧為噺锛?| 鏄?|
| GET | `/m/api/events` | SSE 浜嬩欢娴侊紙session/event 鎽樿锛?| 鏄?|
| GET | `/m/api/catalog` | 妯″瀷/鎺ㄧ悊/鏉冮檺/棰勮鐩綍 | 鏄?|
| GET/POST | `/m/api/session-config` | 浼氳瘽閰嶇疆璇?鏀?| 鏄?|
| POST | `/m/api/sessions` | 鏂板缓浼氳瘽 | 鏄?|
| GET | `/m/api/notifications` | 閫氱煡鍒楄〃 | 鏄?|
| POST | `/m/api/notifications/read` | 鏍囪宸茶 | 鏄?|
| GET | `/m/api/actions` | 鎻掍欢鍔ㄤ綔娓呭崟 | 鏄?|
| POST | `/m/api/actions/:id/invoke` | 鎵ц鎻掍欢鍔ㄤ綔 | 鏄?|
| GET | `/m/api/usage` | 浼氳瘽 token 鐢ㄩ噺 | 鏄?|
| GET | `/m/api/workspaces` | 宸叉敞鍐屽伐浣滃尯 | 鏄?|
| GET/POST | `/m/api/directories` | 鐩綍娴忚/鏂板缓鏂囦欢澶?| 鏄?|
| GET | `/m/api/diagnostics` | 鐜璇婃柇 | 鏄?|
| GET | `/m/api/balance` | DeepSeek 瀹樻柟浣欓 | 鏄?|
| GET | `/m/api/qr-config` | 妗岄潰浜岀淮鐮佹暟鎹紙loopback only锛?| 鍚︼紙loopback锛?|
| POST | `/m/api/defaults` | 淇敼榛樿 Agent/鏉冮檺棰勮 | 鏄?|
| GET | `/m/qr.png` | 浜岀淮鐮?PNG | 鍚?|

## 3. 绔偣璇﹁堪锛坴1 鏃㈡湁绔偣锛?
### 3.1 GET /m/api/bootstrap

**鍝嶅簲 200**

```json
{
  "ok": true,
  "auth": { "enabled": false },
  "server": {
    "port": 3080,
    "urls": ["http://192.168.1.5:3080", "http://100.101.102.103:3080", "http://127.0.0.1:3080"]
  },
  "agents": [
    { "id": "session-abc", "status": "running", "hasPending": false }
  ],
  "sessions": [
    { "id": "session-abc", "createdAt": 1750000000000, "cwd": "F:\\DSH-Outpost" }
  ]
}
```

- `urls`锛氭寜浼樺厛绾ф帓鍒椻€斺€旈涓潪 internal IPv4锛堝惈 Tailscale 100.x 娈碉級鍦ㄥ墠锛宭oopback 鏈€鍚庯紱`port` 鏉ヨ嚜 `ctx.webServer.port`銆?- `agents[].status`锛歚"running" | "idle"`锛堟槧灏勮嚜 agent 鐘舵€?鏈€杩戜簨浠舵帹鏂級銆?- 鏈璇侊細`401`锛堣閫氱敤绾﹀畾锛夈€?
### 3.2 POST /m/api/send
**璇锋眰**

```json
{ "sessionId": "session-abc", "text": "甯垜璺戜竴涓嬫祴璇? }
```

- `sessionId` 鍙€夛細鎸囧畾浼氳瘽锛堝繀椤诲瓨鍦ㄤ笖鍏?agent 瀛樻椿锛夛紱缂虹渷 鈫?绗竴涓?root agent銆?
**鍝嶅簲**

- `200 { "ok": true, "agentId": "session-abc", "messageId": "m_<uuid>" }`
- `400 { "error": "empty-text" }`锛歵ext 涓虹┖鎴栭潪瀛楃涓?- `404 { "error": "session-not-found" }`锛氭寚瀹氫細璇濅笉瀛樺湪
- `503 { "error": "no-live-agent" }`锛氭棤鍖归厤鐨勮繍琛屼腑 agent
- `503 { "error": "agents-unavailable" }`锛歛gents 鏈嶅姟涓嶅彲鐢紙闈?web 缁勫悎鎴栧惎鍔ㄤ腑锛?
**璇箟**锛氭湇鍔＄鏋勯€?`createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })` 鍚庤皟鐢?`agent.followup(message)`銆俙followup` 浼氭寔涔呭寲娑堟伅骞跺敜閱掔┖闂查┍鍔ㄥ櫒锛涗笉绛夊緟鎵ц缁撴灉锛堢粨鏋滅粡 SSE 鍥炴祦锛夈€?
### 3.3 GET /m/api/sessions

**鍝嶅簲 200**

```json
{
  "ok": true,
  "sessions": [
    { "id": "session-abc", "createdAt": 1750000000000, "cwd": "F:\\DSH-Outpost", "lastEventSeq": 42 }
  ]
}
```

鎺掑簭锛歚createdAt` 鍊掑簭銆傛暟鎹簮 `ctx.sessions.list()`銆?
### 3.4 GET /m/api/history

**鏌ヨ鍙傛暟**

- `sessionId`锛堝繀濉級锛氱洰鏍囦細璇?- `after`锛堝彲閫夛級锛?*澧為噺妯″紡**鈥斺€斿彧杩斿洖 `seq > after` 鐨勪簨浠讹紙SSE 閲嶈繛琛ユ紡鐢級銆?- `before`锛堝彲閫夛級锛?*涓婄炕鍒嗛〉**鈥斺€斿彧杩斿洖 `seq < before` 鐨勬渶杩?`limit` 鏉′簨浠讹紙瀵硅瘽鍐呮粴鍔ㄥ埌椤堕儴鍔犺浇鏇存棭锛夈€?- 涓夌妯″紡浼樺厛绾э細`after` > `before` > 鍒濆鍔犺浇锛堢己鐪佹椂杩斿洖鏈€杩?`limit` 鏉★紝鍗冲熬閮級銆?- `limit`锛堝彲閫夛紝榛樿 500锛屼笂闄?1000锛夛細鏈€澶氳繑鍥炴潯鏁?
**杩囨护瑙勫垯**锛氬彧杩斿洖浼氳瘽"琛ㄩ潰"浜嬩欢锛坄user/message`銆乣assistant/message`銆乣tool/call`銆乣tool/result`銆乣turn/start`銆乣turn/end`锛夈€倀oken 绾?`assistant/chunk`銆乣agent/inbox/spliced`銆乣request/*` 绛夋棩蹇楀瀷浜嬩欢涓嶈繑鍥烇紙鏁伴噺鍙揪鍗佷竾绾э紝浼氭饭娌＄Щ鍔ㄧ锛涘畬鏁村洖澶嶇敱 `assistant/message` 鍏滃簳锛夈€係SE 瀹炴椂娴佷笉鍙楁杩囨护褰卞搷銆?
**鍝嶅簲 200**

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "after": 42,
  "events": [
    { "seq": 43, "type": "user/message", "data": { "text": "甯垜璺戜竴涓嬫祴璇? } }
  ]
}
```

`events[]` 浣跨敤涓?SSE 甯х浉鍚岀殑鎽樿鏍煎紡锛堣 3.7锛夛紝淇濊瘉瀹㈡埛绔幓閲嶉€昏緫鍗曚竴銆傛暟鎹簮锛歚ctx.sessions.get(id).events`锛堣拷鍔犲紡鍐荤粨蹇収锛屽ぉ鐒舵寜 seq 鏈夊簭锛夈€?
- `404 { "error": "session-not-found" }`

### 3.5 GET /m/api/events（SSE）
`Content-Type: text/event-stream`銆傚抚鏍煎紡锛坄data:` 鍗曡 JSON锛夛細

```json
{ "type": "session/event", "sessionId": "session-abc", "seq": 44, "event": { "type": "turn/end", "data": { "reason": { "kind": "complete" } } } }
```

**浜嬩欢鎽樿 `event` 瀛楁**锛堟湇鍔＄瑁佸壀锛岃 02 搂5.2锛夛細

| event.type | event.data 鍐呭 |
|---|---|
| `user/message` | `{ text: string }`锛坱ext blocks 鎷兼帴锛屸墹2000 瀛楃锛?|
| `assistant/message` | `{ text: string, reasoningChars: number }` |
| `assistant/chunk` | `{ text: string }`锛堜粎鏂囨湰 delta锛?|
| `tool/result` | `{ name: string, isError: boolean, text: string }`锛堚墹2000 瀛楃锛?|
| `turn/start` | `{ turn: number }` |
| `turn/end` | `{ turn: number, reason: object }` |
| 鍏朵粬 | 浠?`type`锛屾棤 data锛堝鎴风蹇界暐锛?|

**鎺у埗甯?*锛氳繛鎺ュ缓绔嬪悗绔嬪嵆 `data: {"type":"hello","serverTime":...}`锛涙瘡 25s `: ping` 娉ㄩ噴琛屻€?
**閿欒璇箟**锛氶壌鏉冨け璐ュ湪杩炴帴寤虹珛闃舵浠?`401` HTTP 鐘舵€佽繑鍥烇紙EventSource 浼氳Е鍙?error 浜嬩欢锛屽鎴风杞櫥褰曟€侊級銆?
### 3.6 GET /m/qr.png

**鏌ヨ鍙傛暟**锛歚text`锛堝繀濉紝浜岀淮鐮佸唴瀹癸紝URL 缂栫爜锛夈€傛棤 `text` 鈫?`400`銆?**鍝嶅簲**锛歚200 image/png`锛坬rcode 鍖呯敓鎴愶紝灏哄 512锛岀籂閿欑骇鍒?M锛夈€?
## 4. 閿欒鐮佹眹鎬?
| HTTP | error 鍊?| 鍦烘櫙 |
|---|---|---|
| 400 | `bad-request` | JSON 瑙ｆ瀽澶辫触 / 缂哄弬 / 鍙傛暟绫诲瀷閿欒 |
| 400 | `empty-text` | send 鐨?text 涓虹┖ |
| 401 | `auth-required` | 鏈彁渚涙湁鏁堝嚟璇?|
| 401 | `bad-token` | 鐧诲綍鍙ｄ护閿欒 |
| 404 | `not-found` | 鏈煡璺緞 |
| 404 | `session-not-found` | 浼氳瘽涓嶅瓨鍦?|
| 405 | `method-not-allowed` | 鏂规硶涓嶆敮鎸侊紙GET 绔偣鏀跺埌 POST 绛夛級 |
| 503 | `no-live-agent` | 鏃犺繍琛屼腑 agent |
| 503 | `agents-unavailable` | agents 鏈嶅姟涓嶅彲鐢?|

## 5. 鐗堟湰鍏煎绛栫暐

- 绔偣浠呰拷鍔犮€佷笉鐮村潖鎬т慨鏀癸紱`event` 鎽樿鏍煎紡鍏佽澧炲姞瀛楁锛岀姝㈠垹闄?閲嶅懡鍚嶆棦鏈夊瓧娈点€?- 鍓嶇涓庡悗绔悓鍖呭彂甯冿紙鍗曟枃浠堕〉闈㈢敱鎻掍欢鑷韩鏈嶅姟锛夛紝鏃犺法鐗堟湰閮ㄧ讲闂銆?
## 6. 绉诲姩绔柊澧炵鐐癸紙Phase 1锛寁2.0锛?
> 鍏ㄩ儴瑕佹眰閴存潈锛堜笌鏃㈡湁绔偣涓€鑷达級锛涘啓鎿嶄綔閬靛惊涓?PC 绔浉鍚岀殑纭璇箟锛堝 Full Access 椋庨櫓纭鐢卞鎴风鍏堣锛屾湇鍔＄鍦ㄥ弬鏁颁腑鎼哄甫纭鏍囪锛夈€?
### 6.1 绔偣鎬昏〃

| 鏂规硶 | 璺緞 | 鐢ㄩ€?|
|---|---|---|
| GET | `/m/api/catalog` | 妯″瀷鐩綍 + 鎺ㄧ悊寮哄害 + 鏉冮檺棰勮 + Agent 棰勮锛堝叏閮ㄦ灇涓撅紝涓€娆℃媺鍙栵級 |
| GET | `/m/api/session-config` | 褰撳墠浼氳瘽閰嶇疆锛堟ā鍨?鎺ㄧ悊寮哄害/鏉冮檺/棰勮锛?|
| POST | `/m/api/session-config` | 鏇存柊褰撳墠浼氳瘽閰嶇疆 |
| POST | `/m/api/sessions` | 鏂板缓浼氳瘽锛坧reset 鍙傛暟锛?|
| GET | `/m/api/notifications` | 閫氱煡鍒楄〃锛堟湭璇?宸茶锛?|
| POST | `/m/api/notifications/read` | 鏍囪宸茶锛堝崟鏉?鍏ㄩ儴锛?|
| GET | `/m/api/actions` | 鎻掍欢鍔ㄤ綔娓呭崟锛堝疄鏃讹級 |
| POST | `/m/api/actions/:id/invoke` | 鎵ц鎻掍欢鍔ㄤ綔 |
| GET | `/m/api/usage` | 浼氳瘽 token 鐢ㄩ噺缁熻锛坴2.1锛?|
| GET | `/m/api/workspaces` | 宸叉敞鍐屽伐浣滃尯锛堟柊寤轰細璇濋粯璁ょ洰褰曪紝v2.1锛?|
| GET | `/m/api/directories` | 鐩綍娴忚锛堢洏绗?瀛愮洰褰曪紝v2.1锛?|
| POST | `/m/api/directories` | 鏂板缓鏂囦欢澶癸紙v2.1锛?|
| GET | `/m/api/diagnostics` | 鐜璇婃柇锛堟湇鍔?绔偣瀹炴祴锛寁2.1锛?|
| GET | `/m/api/balance` | DeepSeek 瀹樻柟浣欓锛堟湇鍔＄浠ｆ煡锛寁2.1锛?|
| GET | `/m/api/qr-config` | 妗岄潰浜岀淮鐮佹暟鎹紙loopback only锛寁2.1锛?|
| POST | `/m/api/defaults` | 淇敼榛樿 Agent/鏉冮檺棰勮锛坴2.1锛?|

### 6.2 GET /m/api/catalog

杩斿洖 PC 绔湡瀹炴灇涓撅紙鍗曚竴浜嬪疄婧愶紝瀹㈡埛绔笉纭紪鐮侊級锛?
```json
{
  "ok": true,
  "models": [
    { "id": "deepseek-v4-flash", "name": "DeepSeek-V4-Flash" },
    { "id": "deepseek-v4-pro", "name": "DeepSeek-V4-Pro" }
  ],
  "reasoningEfforts": ["off", "high", "max"],
  "permissionPresets": [
    { "id": "read-only", "name": "Read Only", "description": "鍙 路 鎷掔粷涓€鍒囧啓鍏ユ搷浣? },
    { "id": "workspace-write", "name": "Workspace Write", "description": "浠呭伐浣滃尯鍐呰鍐?路 鍗遍櫓鎿嶄綔鍓嶈闂? },
    { "id": "danger-full-access", "name": "Danger Full Access", "description": "瀹屽叏璁块棶 路 鍙墽琛屼换浣曟搷浣? }
  ],
  "agentPresets": [
    { "id": "standard", "name": "鏍囧噯妯″紡", "description": "鍔熻兘瀹屾暣鐨勭紪鐮?Agent锛氭枃浠剁紪杈戙€丼hell銆佹枃浠朵笌缃戦〉妫€绱€丼kills銆佽鍒掋€佺洰鏍囥€佸瓙浠ｇ悊鍜屽伐浣滄祦" },
    { "id": "code", "name": "PTC 妯″紡", "description": "鈥? },
    { "id": "minimal", "name": "鏋佺畝妯″紡", "description": "鈥? },
    { "id": "cordis", "name": "鍒涢€犳ā寮?, "description": "鈥? }
  ],
  "defaults": {
    "model": "deepseek-v4-flash",
    "reasoningEffort": "max",
    "permissionPreset": "workspace-write",
    "agentPreset": "standard"
  }
}
```

鏁版嵁鏉ユ簮锛歚ctx.llm.listProviders()/listModels()`銆乸rovider 閰嶇疆锛坮easoningEffort 鏋氫妇锛夈€乣ctx.sandboxPolicy`/permission-presets 鏈嶅姟銆乤gent-presets 鐩綍 manifest锛坣ame/description锛夈€傞粯璁ゅ€兼潵鑷?settings/閰嶇疆鏍戙€?
### 6.3 GET /m/api/session-config

```json
{
  "ok": true,
  "sessionId": "session-abc",
  "config": {
    "model": "deepseek-v4-flash",
    "reasoningEffort": "max",
    "permissionPreset": "workspace-write"
  }
}
```

### 6.4 POST /m/api/session-config

**璇锋眰**锛堜笁涓瓧娈靛潎鍙€夛紝鍙洿鏂扮粰瀹氶」锛夛細

```json
{
  "sessionId": "session-abc",
  "model": "deepseek-v4-pro",
  "reasoningEffort": "high",
  "permissionPreset": "danger-full-access",
  "confirmDanger": true
}
```

- `permissionPreset` 涓?`danger-full-access` 鏃?`confirmDanger` 蹇呴』涓?`true`锛屽惁鍒?`400 { "error": "risk-confirmation-required" }`锛堜笌 PC 绔?Full access 闇€鏄惧紡纭椋庨櫓"涓€鑷达級銆?- 鏉冮檺鍐欏叆璧?PC 绔悓涓€璺緞锛坄permission/preset` + sandbox/approval 鏃嬮挳浜嬩欢锛夈€?- 淇敼褰撳墠浼氳瘽閰嶇疆涓嶅垱寤烘柊浜嬩欢涔嬪鐨勪簨瀹烇紱`404 session-not-found`銆?
### 6.5 POST /m/api/sessions锛堟柊寤轰細璇濓級

**璇锋眰**锛?
```json
{
  "preset": "standard",
  "model": "deepseek-v4-flash",
  "reasoningEffort": "max",
  "permissionPreset": "workspace-write"
}
```

- `preset` 蹇呭～锛堝鎴风浠?catalog 閫夋嫨锛涢粯璁ゅ€肩敱鏈嶅姟绔?`defaults.agentPreset` 鍏滃簳锛夛紱鍏朵綑鍙€夈€?- 鏈嶅姟绔細`ctx.agents.create({ preset, ... })`锛堟寜 preset 缁勫悎浼氳瘽锛夛紝闅忓悗鎸夊弬鏁拌鍐欓厤缃€?
**鍝嶅簲**锛歚200 { "ok": true, "sessionId": "session-xyz", "agentId": "session-xyz" }`鈥斺€斿鎴风闅忓嵆鍙?`POST /api/send` 鎴栬闃?SSE 璇ヤ細璇濄€?
### 6.6 GET /m/api/notifications

閫氱煡鐢辨湇鍔＄浠庝細璇濅簨浠舵祦**鑱氬悎**锛堜笉鏂板瀛樺偍锛夛細

```json
{
  "ok": true,
  "unread": 2,
  "items": [
    { "id": "n-1", "kind": "needs-answer", "sessionId": "session-abc", "title": "闇€瑕佷綘鍥炵瓟", "detail": "鍙戠幇 214 涓噸澶嶆枃浠讹紝鏄惁鍒犻櫎浠ラ噴鏀剧┖闂达紵", "time": 1750000000000, "unread": true },
    { "id": "n-2", "kind": "completed", "sessionId": "session-abc", "title": "浠诲姟瀹屾垚", "detail": "澶囦唤閰嶇疆鍒?E 鐩橈紙鑰楁椂 4 鍒嗛挓锛?, "time": 1750000000000, "unread": true },
    { "id": "n-3", "kind": "failed", "sessionId": "session-def", "title": "浠诲姟澶辫触", "detail": "鏃ュ織鍒嗘瀽浠诲姟鎵ц澶辫触锛屽凡鑷姩閲嶈瘯", "time": 1750000000000, "unread": false }
  ]
}
```

- `kind`锛歚completed`锛坱urn/end 姝ｅ父锛夈€乣needs-answer`锛堢瓑寰呬汉绫诲喅绛栤€斺€斾粠瀹℃壒/鎻愰棶鐩稿叧浜嬩欢鎺ㄥ锛孭hase 1 瀹炵幇鏃堕獙璇佽涔夛級銆乣failed`锛坱urn/end 寮傚父/aborted锛夈€?- **鏈鐘舵€佹寔涔呭寲**锛氭彃浠跺湪 settings 鍩熶繚瀛樺凡璇?id 闆嗗悎锛坄ctx.settings`锛夛紝鏈嶅姟閲嶅惎涓嶄涪銆?- 鎺掑簭锛氭椂闂村€掑簭锛涗笂闄?100 鏉°€?
### 6.7 POST /m/api/notifications/read

```json
{ "ids": ["n-1", "n-2"] }
```
鎴?`{ "all": true }`銆傚搷搴?`200 { "ok": true }`銆?
### 6.8 GET /m/api/actions

**鍔ㄤ綔濂戠害 v0.1**锛堝彲閫夎兘鍔涳紝鎻掍欢涓嶆敞鍐屽垯杩斿洖绌烘暟缁勶紝瀹㈡埛绔殣钘忓姩浣滃尯锛夛細

```json
{
  "ok": true,
  "actions": [
    { "id": "fs-cleanup", "title": "娓呯悊纾佺洏", "icon": "trash", "fields": [ { "key": "target", "label": "鐩爣鐩綍", "placeholder": "濡?F:\\璧勬枡" } ] },
    { "id": "test-run", "title": "璺戞祴璇?, "icon": "zap", "fields": [] }
  ]
}
```

- 鏈嶅姟绔敞鍐岃〃锛歚ctx.mobileActions.register({ id, title, icon, fields?, handler })`鈥斺€攊d 鍐茬獊鎶涢敊锛圕ordis 璇箟锛夛紱鎻掍欢鍗歌浇闅?fiber dispose 鑷姩绉婚櫎銆?- `icon` 闄愬畾涓虹Щ鍔ㄧ鍐呯疆鍥炬爣搴撶殑 id锛堜笉鍏佽鎻掍欢鑷甫 UI/鍥炬爣锛夈€?- `fields`锛歷0.1 浠呮敮鎸?`text` 绫诲瀷瀛楁銆?
### 6.9 POST /m/api/actions/:id/invoke

**璇锋眰**锛歚{ "args": { "target": "F:\\璧勬枡" } }`

- 鏈嶅姟绔牎楠屾敞鍐岃〃瀛樺湪涓庡弬鏁扮被鍨嬶紝璋冪敤 `handler(args)`锛堣窇鍦ㄧ數鑴戠锛夈€?- 鎵ц缁撴灉**涓嶇洿鎺ヨ繑鍥?*锛堝彲鑳介暱浠诲姟锛夛細`200 { "ok": true, "accepted": true }`锛涘悗缁繘灞曠粡 SSE 浼氳瘽浜嬩欢鍥炴祦锛堝姩浣滃簲閫氳繃鏃㈡湁娑堟伅/宸ュ叿閫氶亾鍛堢幇锛夈€?
### 6.10 GET /m/api/qr-config锛堟闈簩缁寸爜鏁版嵁锛寁2.1锛?
**浠呯數鑴戞湰鏈哄彲璁块棶**锛圱CP socket 鏉ユ簮涓?loopback锛屽惁鍒?403 `loopback-only`锛夆€斺€?妗岄潰 dsh 璁剧疆椤靛鎴风妯″潡鐢ㄥ畠鐢熸垚銆岃繛鎺ョЩ鍔ㄧ璁惧銆嶄簩缁寸爜銆?
**鍝嶅簲**锛歚{ "ok": true, "urls": ["http://192.168.1.100:3080/m", ...], "token": "<authToken>", "path": "/m" }`

浜岀淮鐮佸唴瀹规牸寮忥細`DSHREMOTE|<鍦板潃>|<鍙ｄ护>`锛堝湴鍧€涓?urls 涓涓潪鍥炵幆椤癸紝涓嶅惈 /m 灏惧反锛夈€侫pp 鎵爜瑙ｆ瀽鍚庤嚜鍔ㄩ厤缃繛鎺ャ€?
### 6.11 POST /m/api/defaults锛堜慨鏀归粯璁ら厤缃紝v2.1锛?
淇敼**榛樿 Agent 棰勮 / 榛樿鏉冮檺棰勮**锛堜綔鐢ㄤ簬涔嬪悗鏂板缓鐨勪細璇濓級锛屼笌 PC 绔缃〉鍚屼竴鍐欏叆閫氶亾锛堣蛋 `/api` 妗?`settings.update`锛屼笉鍦?HTTP 鍥炶皟鐩存帴璋?settings 鏈嶅姟锛夈€?
**璇锋眰**锛歚{ "agentPreset": "code", "permissionPreset": "workspace-write" }`锛堜袱鑰呭潎鍙€夛級

**鍝嶅簲**锛歚200 { "ok": true }`锛涘け璐?`400 { "error": "update-failed", "detail": "<鍘熷洜>" }`

### 6.12 閿欒鐮佽ˉ鍏?
| HTTP | error 鍊?| 鍦烘櫙 |
|---|---|---|
| 400 | `risk-confirmation-required` | 閫?danger-full-access 鏈甫 confirmDanger |
| 400 | `invalid-preset` | preset 涓嶅湪鐩綍涓?|
| 404 | `action-not-found` | 鍔ㄤ綔 id 鏈敞鍐?|
| 503 | `action-busy` | 鍚屼竴鍔ㄤ綔骞跺彂鎵ц闄愬埗锛坴0.1 鍙厛涓嶅仛锛?|




