# 05 娴嬭瘯鐢ㄤ緥璁捐鏂囨。 鈥?dsh-mobile-remote

> 鐗堟湰锛歷0.2 路 鐘舵€侊細宸叉寜瀹為檯楠岃瘉缁撴灉濉啓 路 閰嶅锛?3-api.md銆?4-security.md
> 鐜锛歐indows + dsh web锛坵eb profile锛? Android锛圖SH Remote App锛?> 鍓嶇疆锛氭彃浠跺凡瀹夎骞跺惎鐢紱璁块棶鍙ｄ护涓哄畨瑁呮椂鐢熸垚鐨勯殢鏈轰覆锛堜笅绉?`<TOKEN>`锛夈€?
## 1. 娴嬭瘯鑼冨洿涓庣幆澧?
- 鍔熻兘锛氳璇併€佸彂娑堟伅銆佷簨浠跺洖娴併€佸巻鍙层€佷細璇濄€侀€氱煡銆佹柊寤轰細璇濄€佺洰褰曘€侀粯璁ら厤缃€佷簩缁寸爜銆?- 瀹夊叏锛氬彛浠ゆ牎楠屻€丠ost 鏍￠獙銆乴oopback 闄愬埗銆?- 鍏煎锛欰ndroid 娣辫壊/娴呰壊涓婚銆?- 鑷姩鍖栵細`tools/e2e-check.mjs`锛圢ode 鈮?20锛宍DSH_MOBILE_TOKEN` 鐜鍙橀噺锛夎鐩栨牳蹇?API 閾捐矾銆?
## 2. 鍔熻兘娴嬭瘯鐢ㄤ緥

### F-01 璁よ瘉锛氭湭鎼哄甫鍑瘉璁块棶 API

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 涓嶅甫鍑瘉璇锋眰 `GET /m/api/bootstrap` |
| 棰勬湡 | 401 `{"error":"auth-required"}` |

### F-02 璁よ瘉锛氶敊璇彛浠?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 鎼哄甫閿欒 token 璇锋眰 `GET /m/api/bootstrap` |
| 棰勬湡 | 401 `{"error":"auth-required"}` |

### F-03 璁よ瘉锛氭纭彛浠?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 鎼哄甫姝ｇ‘ token锛坄X-Mobile-Token` 澶达級璇锋眰 `GET /m/api/bootstrap` |
| 棰勬湡 | 200 `{"ok":true}` |

### F-04 bootstrap 鐘舵€?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 甯?token 璇锋眰 `/m/api/bootstrap` |
| 棰勬湡 | 200锛沗auth.enabled=true`锛沗server.urls` 鍚眬鍩熺綉 IPv4 涓?127.0.0.1锛沗agents` 鍚繍琛屼腑浼氳瘽锛沗sessions` 闈炵┖ |

### F-05 鍙戞秷鎭紙绔埌绔紝鑷姩鍖栬鐩栵級

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 杩?SSE锛堝甫 token锛夆啋 `POST /m/api/send {sessionId, text}` |
| 棰勬湡 | send 200 `{ok, agentId, messageId}`锛汼SE 鏀跺埌 `session/event` 甯э紙user/message 鈫?assistant/message锛?|
| 瀹炴祴 | 鉁?绔埌绔€氳繃锛圓pp 鍙戦€?鈫?浼氳瘽鏀跺埌 鈫?鍥炲鍥炴祦锛?|

### F-06 鍙戞秷鎭細绌烘枃鏈?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `POST /m/api/send {text:""}` |
| 棰勬湡 | 400 `{"error":"empty-text"}` |

### F-07 鍙戞秷鎭細鏃犺繍琛屼腑 agent

| 椤?| 鍐呭 |
|---|---|
| 鍓嶇疆 | 鐢佃剳绔棤浠讳綍浼氳瘽 |
| 姝ラ | `POST /m/api/send`锛堜笉甯?sessionId锛?|
| 棰勬湡 | 503 `{"error":"no-live-agent"}` |

### F-08 鍘嗗彶鍔犺浇

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `GET /m/api/history?sessionId=<id>&after=0&limit=200` |
| 棰勬湡 | 200锛涗簨浠舵寜 seq 鍗囧簭锛屾憳瑕佹牸寮忎笌 SSE 涓€鑷?|

### F-09 鏂板缓浼氳瘽

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `POST /m/api/sessions {preset, cwd}` |
| 棰勬湡 | 200 `{sessionId}`锛汸C 绔細璇濆垪琛ㄥ嚭鐜帮紱cwd 鍦ㄥ伐浣滃尯瀛愮洰褰曟椂鑷姩褰掑睘璇ュ伐浣滃尯 |

### F-10 閫氱煡涓庡凡璇?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 浠诲姟瀹屾垚 鈫?`GET /m/api/notifications` 鈫?`POST /m/api/notifications/read` |
| 棰勬湡 | 閫氱煡鍑虹幇涓斿悓浼氳瘽鍚岀被鍨嬭仛鍚堜负涓€鏉★紱鏍囪宸茶鍚?unread 褰掗浂 |

### F-11 榛樿閰嶇疆淇敼

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `POST /m/api/defaults {agentPreset:"code"}` |
| 棰勬湡 | 200锛沗GET /m/api/catalog` 鐨?defaults.agentPreset 鍙樻洿涓?code |

### F-12 浜岀淮鐮佺鐐?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `GET /m/qr.png?text=<url>` |
| 棰勬湡 | 杩斿洖 `image/png` |

### F-13 妗岄潰浜岀淮鐮佹暟鎹紙qr-config锛?
| 椤?| 鍐呭 |
|---|---|
| 姝ラ | loopback 璇锋眰 `GET /m/api/qr-config` |
| 棰勬湡 | 200 `{urls, token, path}`锛涢潪 loopback 鈫?403 |

### F-14 鐩綍娴忚

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `GET /m/api/directories?path=` 鈫?鐩樼锛沗?path=F:\` 鈫?瀛愮洰褰曪紱`POST /m/api/directories {path,name}` |
| 棰勬湡 | 鐩樼/瀛愮洰褰曞垪琛ㄦ纭紱鏂板缓鏂囦欢澶规垚鍔?|

## 3. 瀹夊叏娴嬭瘯鐢ㄤ緥

### S-01 Host 鏍￠獙

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 璇锋眰澶?`Host: evil.example.com` 璁块棶 `/m/api/bootstrap`锛堝甫鏈夋晥 token锛?|
| 棰勬湡 | 403 `{"error":"host-not-allowed"}` |

### S-02 qr-config loopback 闄愬埗

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | 闈?loopback 鏉ユ簮璇锋眰 `GET /m/api/qr-config` |
| 棰勬湡 | 403 `{"error":"loopback-only"}` |

### S-03 鍙ｄ护鍏抽棴妯″紡

| 椤?| 鍐呭 |
|---|---|
| 鍓嶇疆 | patch 涓?`authToken` 缃┖骞堕噸鍚?|
| 姝ラ | 鏃犲嚟璇佽闂?`/m/api/bootstrap` |
| 棰勬湡 | 200锛堟棤璁よ瘉锛?|

### S-04 鐩戝惉鑼冨洿

| 椤?| 鍐呭 |
|---|---|
| 姝ラ | `netstat`/`Get-NetTCPConnection` 鏌ョ湅 3080 鐩戝惉鍦板潃 |
| 棰勬湡 | `0.0.0.0:3080`锛堝凡閰嶇疆灞€鍩熺綉/Tailscale 璁块棶鏃讹級锛涚‘璁ゅ叕缃戠鍙ｆ湭寮€鏀?|

## 4. 鍥炲綊鎵ц寤鸿

- 姣忔淇敼鎻掍欢婧愮爜鍚庯細`cd C:\Users\<浣?\.dsh\profiles\web && corepack pnpm install`锛堝悓姝?file: 鍓湰锛夆啋 閲嶅惎 dsh web 鈫?璺?`tools/e2e-check.mjs` 鈫?鎵嬫満 App 鍐掔儫锛堣繛鎺?鍙戞秷鎭?閫氱煡/鏂板缓浼氳瘽锛夈€?- 淇敼 App 鍚庯細`flutter analyze` 鈫?`flutter build apk --release` 鈫?瑕嗙洊瀹夎銆?
