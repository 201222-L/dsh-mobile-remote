# 06 閮ㄧ讲涓庡惎鐢ㄦ枃妗?鈥?dsh-mobile-remote

> 鐗堟湰锛歷0.3 路 鐘舵€侊細宸插湪鏈満瀹屾垚瀹夎涓庨獙璇?路 閰嶅锛?4-security.md銆?7-user-manual.md

## 1. 閮ㄧ讲鎷撴墤

```mermaid
graph LR
    PH[鎵嬫満锛圖SH Remote App锛塢 -->|鍚屼竴 WiFi 鎴?Tailscale| PC[鐢佃剳 dsh web :3080 缁?0.0.0.0]
    PC --> PL[dsh-mobile-remote 鎻掍欢 /m/api]
    PL --> DSH[dsh services: agents / sessions]
    PH -.澶栧嚭.-> TS[Tailscale 铏氭嫙缃?br/>WireGuard 鍔犲瘑+璁惧璁よ瘉] -.-> PC
```

- 鎵嬫満绔細瀹夎 DSH Remote App锛堟瀯寤烘柟娉曡 搂8锛夛紝App 杩炴帴鐢佃剳鍦板潃锛堝 `http://192.168.1.100:3080`锛夈€?- 妗岄潰绔叆鍙ｏ細dsh 璁剧疆椤点€岃繛鎺ョЩ鍔ㄧ璁惧銆嶏紙鎻掍欢瀹㈡埛绔ā鍧楋級鏄剧ず鎵爜浜岀淮鐮佷笌杩炴帴淇℃伅銆?- 澶栧嚭璁块棶锛歍ailscale 缁勭綉鍚?App 杩炴帴 `http://<Tailscale IP>:3080`銆?
## 2. 瀹夎浣嶇疆璇存槑锛堥€氱敤锛?
| 椤?| 浣嶇疆 |
|---|---|
| 鎻掍欢婧愮爜 | `<鏈粨搴?/`锛坧ackage.json / lib / docs / tools锛?|
| 宸插畨瑁呭壇鏈?| `~/.dsh/profiles/web/node_modules/dsh-mobile-remote/` |
| profile 渚濊禆澹版槑 | `~/.dsh/profiles/web/package.json` 鈫?`"dsh-mobile-remote": "file:<鏈粨搴撹矾寰?"` |
| 鍚敤閰嶇疆 | `~/.dsh/profiles/web/cordis.patch.yml`锛坕nsert mobile-remote + webserver 0.0.0.0锛?|
| 璁块棶鍙ｄ护 | 閮ㄧ讲鏃剁敓鎴愶紙`crypto.randomBytes(24).toString('base64url')`锛夛紝鍐欏叆 `authToken` |

## 3. 鍚敤/閲嶅惎姝ラ

```powershell
# 1. 淇敼鎻掍欢婧愮爜鍚庯紝鍚屾宸插畨瑁呭壇鏈紙file: 渚濊禆涓嶄細鑷姩閲嶈锛?cd ~/.dsh/profiles/web
corepack pnpm install

# 2. 妫€鏌ョ粍鍚堥厤缃紙涓嶅惎鍔級
npx @deepseek-ai/dsh --profile web --dump-config
# 纭杈撳嚭鍖呭惈 mobile-remote 琛屼笌 webserver host: 0.0.0.0

# 3. 閲嶅惎 dsh web
npx @deepseek-ai/dsh web
```

鍚姩鎴愬姛鍚庢帶鍒跺彴浼氭墦鍗帮細
`dsh web: http://127.0.0.1:3080 (LAN: http://192.168.x.x:3080)`

## 4. 鍙樻洿閰嶇疆锛堝彛浠?璺緞/鍏呭€煎湴鍧€锛?
缂栬緫 `cordis.patch.yml` 涓?`mobile-remote` 琛岀殑 `config`锛岀劧鍚庨噸鍚細

```yaml
- insert:
    - id: mobile-remote
      name: dsh-mobile-remote
      config:
        path: /m
        authToken: <鏂板彛浠わ紝鐣欑┖=鍏抽棴璁よ瘉>
        rechargeUrl: https://platform.deepseek.com/top_up
```

鍙ｄ护鐢熸垚寤鸿锛歚node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"`

## 5. 澶栧嚭璁块棶锛圱ailscale锛?
1. 鐢佃剳瀹夎 [Tailscale](https://tailscale.com/download) 骞剁櫥褰曘€?2. 鎵嬫満瀹夎 Tailscale App 骞剁櫥褰?*鍚屼竴璐﹀彿**銆?3. 涓ょ杩炴帴鍚庯紝鎵嬫満娴忚鍣ㄨ闂?`http://<鐢佃剳Tailscale IP>:3080/m`锛圱ailscale IP 褰㈠ `100.x.x.x`锛涘湪鐢佃剳 `tailscale ip` 鏌ョ湅锛夈€?4. 鏃犻渶寮€鏀惧叕缃戠鍙ｃ€佹棤闇€璺敱鍣ㄩ厤缃紱浼犺緭缁?WireGuard 鍔犲瘑锛岃澶囪韩浠藉嵆璁よ瘉銆?
> 绂佹锛氬皢 3080 绔彛鏄犲皠/绌块€忓埌鍏綉銆傛彃浠舵棤鍐呯疆鍏綉闃叉姢锛堣瑙?04-security.md锛夈€?
## 6. 鎺ㄩ€佹ˉ閰嶇疆锛堝彲閫夛紝閮ㄧ讲鑰?3 鍒嗛挓锛?
> agent 瀹屾垚 / 闇€瑕佷綘鍥炵瓟 / 澶辫触 鈫?鎵嬫満绯荤粺閫氱煡銆?*涓嶉厤缃垯鏃犳帹閫?*锛屽叾浠栧姛鑳戒笉鍙楀奖鍝嶃€?> 鐢佃剳鍙渶鑳芥甯镐笂缃戯紙HTTPS 鍑虹珯锛夛紝鏃犻渶鍏綉绔彛銆?
鍦?`cordis.patch.yml` 鐨?`mobile-remote` 琛?`config` 涓嬪姞 `pushUrls`锛堝彲閰嶅涓€氶亾锛屼簨浠跺悓鏃舵帹閫佸埌鍏ㄩ儴锛夛細

### Server閰憋紙寰俊鎺ㄩ€侊紝瀹夊崜/鍏ㄥ钩鍙伴€氱敤锛?
```yaml
- insert:
    - id: mobile-remote
      name: dsh-mobile-remote
      config:
        path: /m
        authToken: <鍙ｄ护>
        pushUrls:
          - name: 寰俊
            url: https://sctapi.ftqq.com/<浣犵殑SendKey>.send
            format: serverchan
```

SendKey 鑾峰彇锛氭墜鏈哄井淇℃壂鐮佹墦寮€ `https://sct.ftqq.com` 鈫?鐧诲綍 鈫?澶嶅埗 SendKey銆?
### ntfy锛堝畨鍗撶郴缁熼€氱煡鏍忥紝寮€婧愯嚜鎵樼鍙嬪ソ锛?
```yaml
        pushUrls:
          - name: ntfy
            url: https://ntfy.sh/<浣犵殑闅忔満topic>
            format: ntfy
```

鎵嬫満瑁?ntfy App 璁㈤槄鍚屼竴 topic銆傛敞鎰忓叕鍏辨湇鍔″櫒 topic 鍙鐚滄祴锛屽缓璁敤闀块殢鏈轰覆銆?
### Bark锛坕Phone锛?
```yaml
        pushUrls:
          - name: Bark
            url: https://api.day.app/<浣犵殑key>
            format: bark
```

### 閫氱敤 webhook

```yaml
        pushUrls:
          - name: 鑷缓
            url: https://your-server.example.com/hook
            format: generic
```

**楠岃瘉**锛氶厤缃悗閲嶅惎妗岄潰绔紝鎵嬫満绔 agent 璺戜竴涓换鍔★紙鎴栧け璐?鎻愰棶锛夛紝瀵瑰簲寰俊/App 鏀跺埌閫氱煡銆傚悓浼氳瘽鍚岀被鍨?60 绉掑唴鍚堝苟锛坄pushCooldownMs` 鍙皟锛夈€?
## 7. 鍥炴粴鏂规

1. 浠?`cordis.patch.yml` 鍒犻櫎 `mobile-remote` 琛屼笌 `webserver` 瑕嗙洊琛岋紙鎴栨暣浣撹繕鍘熶负 `[]`锛夈€?2. 浠?`package.json` 鍒犻櫎 `dsh-mobile-remote` 渚濊禆骞?`corepack pnpm install`銆?3. 閲嶅惎 dsh web銆傛彃浠惰矾鐢便€丼SE 杩炴帴闅?fiber dispose 鍏ㄩ儴閲婃斁锛屾闈?GUI 涓嶅彈褰卞搷銆?
## 8. Flutter App锛坉sh-mobile-app锛屽畨鍗擄級

> 婧愮爜锛歚dsh-mobile-app/` 瀛愮洰褰曪紙鐙珛 Flutter 宸ョ▼锛屼笌鎻掍欢鍚屼粨搴撳彂甯冿級銆?
### 8.1 鏋舵瀯

App = **鍘熺敓 Flutter 搴旂敤**锛堥潪 WebView锛夛細鍏ㄩ儴鐣岄潰鐢?Flutter 鍘熺敓缁勪欢缁樺埗锛屼笌缃戦〉绔?`/m` 鍏变韩鍚屼竴濂楁彃浠?API 涓庤璁′护鐗岋紙DeepSeek 閰嶈壊锛夈€?
- 杩炴帴锛氭壂鐮佽繛鎺ワ紙鎵闈?dsh 璁剧疆椤点€岃繛鎺ョЩ鍔ㄧ璁惧銆嶄簩缁寸爜锛夋垨鎵嬪姩杈撳湴鍧€+鍙ｄ护銆?- 椤甸潰锛氶椤碉紙娆㈣繋 + 鏈€杩戜細璇?+ 杈撳叆妗嗭級銆佸璇濓紙娴佸紡鍥炲銆丮arkdown銆乼oken 鐢ㄩ噺銆佸伐鍏疯皟鐢ㄦ姌鍙狅級銆佷細璇濆垪琛ㄣ€侀€氱煡涓績銆佽缃紙浣欓/榛樿棰勮/娣辫壊妯″紡/鐜璇婃柇锛夈€佹柊寤轰細璇濓紙妯″紡 + 宸ヤ綔鐩綍璺ㄧ洏娴忚锛夈€?- 鏁版嵁锛氫笌缃戦〉绔浉鍚?鈥斺€?鍏ㄩ儴瀹炴椂璇诲啓 PC 绔?dsh锛屾棤鏈湴鐘舵€併€?
### 8.2 鏋勫缓 APK

鍓嶇疆锛欶lutter SDK锛堟湰椤圭洰鐢?3.47.0锛? Android SDK銆?
```powershell
cd dsh-mobile-app
flutter analyze        # 搴斾负 No issues found
flutter build apk --release
# 浜х墿锛歜uild\app\outputs\flutter-apk\app-release.apk
```

> 棣栨鏋勫缓闇€涓嬭浇 Gradle 渚濊禆锛堢害 5鈥?0 鍒嗛挓锛夛紱鑻ユ姤 Kotlin 澧為噺缂撳瓨鎹熷潖锛坄Could not close incremental caches`锛夛紝`android/gradle.properties` 宸茶 `kotlin.incremental=false`锛屽垹闄?`build` 涓?`.dart_tool` 鍚庨噸璇曘€?> 鏇存崲鍥炬爣锛氭妸 1024脳1024 PNG 瑕嗙洊鍒?`assets/icon-1024.png`锛岃繍琛?`python tools/make_icon.py` 鍚庨噸鏂版瀯寤恒€?
### 8.3 瀹夎涓庝娇鐢?
1. 鎶?`app-release.apk` 浼犲埌鎵嬫満锛堝井淇℃枃浠朵紶杈?缃戠洏/USB锛夛紝鐐瑰嚮瀹夎锛堥渶鍏佽"瀹夎鏈煡鏉ユ簮搴旂敤"锛夈€?2. 鎵撳紑 App 鈫掋€屾壂鐮佽繛鎺ャ€嶅鍑嗙數鑴戝睆骞曚笂鐨勪簩缁寸爜锛堟闈?dsh 璁剧疆 鈫掋€岃繛鎺ョЩ鍔ㄧ璁惧銆嶉〉锛夛紱鎴栨墜鍔ㄨ緭鍏ョ數鑴戝湴鍧€ + 璁块棶鍙ｄ护銆?3. 杩炴帴鎴愬姛杩涘叆棣栭〉锛岀洿鎺ュ彂娑堟伅娲炬椿銆?
> 璇存槑锛欰ndroid 9+ 榛樿绂佹槑鏂?HTTP锛孉pp 宸查厤缃?`usesCleartextTraffic`锛屼粎闄愬眬鍩熺綉/鍐呯綉浣跨敤锛屽嬁鏆撮湶鍏綉銆?
### 8.4 閲嶅缓涓庢洿鏂?
- 鎻掍欢/缃戦〉绔敼鍔?鈫?鎸?搂3 鍚屾骞堕噸鍚?dsh web锛堢綉椤电椤甸潰鏈韩姣忔璇锋眰鐜拌鏂囦欢锛屽埛鏂板嵆鐢熸晥锛夈€?- App 鏀瑰姩 鈫?閲嶆柊 `flutter build apk --release` 骞堕噸瑁呫€?- App 涓庢墜鏈烘祻瑙堝櫒锛?m锛夊彲骞跺瓨浣跨敤锛屽叡浜悓涓€濂?API銆?
## 9. 楠屾敹娓呭崟锛坴0.2锛屽潎宸叉墽琛?鉁咃級

- [x] `--dump-config` 鍚?mobile-remote 琛屼笌 webserver 0.0.0.0
- [x] `GET /m` 杩斿洖绉诲姩椤?- [x] 鏈璇?401 / 閿欒鍙ｄ护 401 / 姝ｇ‘鍙ｄ护 Set-Cookie
- [x] `POST /m/api/send` 娉ㄥ叆鎴愬姛锛?00 + messageId锛?- [x] SSE 杩炴帴 + hello + 浜嬩欢杞彂锛堥噸杩為€€閬裤€佹柇绾胯ˉ鎷夛級
- [x] `/m/qr.png` 杩斿洖 PNG
- [x] 妗岄潰璁剧疆椤点€岃繛鎺ョЩ鍔ㄧ璁惧銆嶄簩缁寸爜 + App 鎵爜鑷姩杩炴帴
- [x] Flutter App锛歛nalyze 闆堕棶棰?+ release 鏋勫缓鎴愬姛 + 鐪熸満鍏ㄦ祦绋嬫祴璇?
