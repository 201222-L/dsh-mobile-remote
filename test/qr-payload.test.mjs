// 回归：二维码载荷的挂载路径拼接（PR #32 / 蔡严庆）
//
// 缺陷：`GET /m/api/qr-config` 返回的 urls **已自带挂载路径**——服务端 lib/index.js 的
// 两条分支都拼了 `${basePath}`（LAN 桥 `http://ip:3082/m`、回环 `http://ip:3080/m`）。
// 而 lib/client.js 旧实现在此处又拼了一次 mount，二维码载荷就成了 `http://ip:3082/m/m`；
// App 端 `_pathOf()`（dsh-mobile-app/lib/api.dart）把整段路径原样当作请求前缀，
// 于是**扫码连接一律 404**（v3.0.0 起，commit 7c1291e 引入；两种模式都中招）。
//
// 本测试钉住修复：把 buildQrPayload 改回 `qrTarget + mount` 即变红。
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * lib/client.js 是浏览器形态（window.__ModuleLoader__.load({ id, factory })），
 * 且只在**函数体内**触碰 document/navigator/fetch，因此可在 vm 里加载并取出 exports。
 */
function loadClientExports() {
	const source = readFileSync(join(here, "..", "lib", "client.js"), "utf8");
	let loaded = null;
	const sandbox = {
		// vm 上下文不提供 WHATWG URL（Node 全局才有），buildQrPayload 依赖它
		URL,
		window: {
			__ModuleLoader__: {
				load(mod) {
					loaded = mod;
				},
			},
		},
	};
	vm.createContext(sandbox);
	vm.runInContext(source, sandbox, { filename: "lib/client.js" });
	assert.ok(loaded, "client.js 应通过 window.__ModuleLoader__.load 注册模块");
	const requireStub = (name) => {
		if (name === "react") return { useState: () => [null, () => {}], useEffect: () => {} };
		if (name === "react/jsx-runtime") return { jsx: () => ({}), jsxs: () => ({}), Fragment: "Fragment" };
		throw new Error(`未预期的依赖：${name}`);
	};
	return loaded.factory(requireStub);
}

const client = loadClientExports();
const { buildQrPayload } = client;

/** 取载荷里的地址段。 */
const targetOf = (payload) => /^DSHREMOTE\|(.+?)\|/.exec(payload)?.[1];

test("LAN 桥地址已自带挂载路径：不再补 mount（不产生 /m/m）", () => {
	const payload = buildQrPayload({
		urls: ["http://192.168.1.5:3082/m", "http://127.0.0.1:3080/m"],
		token: "tok",
		basePath: "/m",
	});
	assert.equal(payload, "DSHREMOTE|http://192.168.1.5:3082/m|tok");
	assert.ok(!payload.includes("/m/m"), "载荷里不应出现双重挂载路径 /m/m");
});

test("回环地址同样自带挂载路径（服务端两条分支都拼 basePath）", () => {
	// 这条覆盖 PR 作者原判断的反例：回环模式并非"url 本身无路径"
	const payload = buildQrPayload({
		urls: ["http://127.0.0.1:3080/m"],
		token: "tok",
		basePath: "/m",
	});
	assert.equal(payload, "DSHREMOTE|http://127.0.0.1:3080/m|tok");
	assert.ok(!payload.includes("/m/m"));
});

test("地址本身不含路径时仍补 mount（兼容裸 url 的服务端）", () => {
	const payload = buildQrPayload({ urls: ["http://10.0.0.7:3080"], token: "t", basePath: "/m" });
	assert.equal(payload, "DSHREMOTE|http://10.0.0.7:3080/m|t");
});

test("自定义挂载路径：无路径时补自定义 mount，已有路径时原样保留", () => {
	assert.equal(
		buildQrPayload({ urls: ["http://10.0.0.7:3080"], token: "t", basePath: "/remote" }),
		"DSHREMOTE|http://10.0.0.7:3080/remote|t",
	);
	assert.equal(
		buildQrPayload({ urls: ["http://10.0.0.7:3080/remote"], token: "t", basePath: "/remote" }),
		"DSHREMOTE|http://10.0.0.7:3080/remote|t",
	);
});

test("地址带尾部斜杠时按“已有路径”处理，不叠加", () => {
	assert.equal(
		buildQrPayload({ urls: ["http://10.0.0.7:3080/m/"], token: "t", basePath: "/m" }),
		"DSHREMOTE|http://10.0.0.7:3080/m/|t",
	);
	// App 端 _pathOf() 会剥掉尾部斜杠，最终仍是 /m
	assert.equal(targetOf(buildQrPayload({ urls: ["http://10.0.0.7:3080/m/"], basePath: "/m" })), "http://10.0.0.7:3080/m/");
});

test("无法解析成 URL 的地址退回“直接补 mount”的兜底分支", () => {
	const payload = buildQrPayload({ urls: ["192.168.1.5:3080"], token: "t", basePath: "/m" });
	assert.equal(payload, "DSHREMOTE|192.168.1.5:3080/m|t");
});

test("首选地址仍优先非回环项（不改变原有选路语义）", () => {
	assert.equal(
		buildQrPayload({
			urls: ["http://127.0.0.1:3080/m", "http://192.168.1.5:3082/m"],
			token: "t",
			basePath: "/m",
		}),
		"DSHREMOTE|http://192.168.1.5:3082/m|t",
	);
});

test("urls 为空时回退默认回环地址并补 mount", () => {
	assert.equal(buildQrPayload({ urls: [], token: "t", basePath: "/m" }), "DSHREMOTE|http://127.0.0.1:3080/m|t");
	assert.equal(buildQrPayload({ token: "t", basePath: "/m" }), "DSHREMOTE|http://127.0.0.1:3080/m|t");
});

test("basePath 缺失时按默认 /m 处理", () => {
	assert.equal(buildQrPayload({ urls: ["http://10.0.0.7:3080"], token: "t" }), "DSHREMOTE|http://10.0.0.7:3080/m|t");
});

test("token 缺失时载荷口令段为空串（不写成 undefined）", () => {
	assert.equal(buildQrPayload({ urls: ["http://10.0.0.7:3080/m"] }), "DSHREMOTE|http://10.0.0.7:3080/m|");
	assert.equal(buildQrPayload({ urls: ["http://10.0.0.7:3080/m"], token: null }), "DSHREMOTE|http://10.0.0.7:3080/m|");
});

test("载荷格式与 App 端 scan_screen 正则 ^DSHREMOTE\\|(.+?)\\|(.*)$ 兼容", () => {
	const payload = buildQrPayload({ urls: ["http://192.168.1.5:3082/m"], token: "abc", basePath: "/m" });
	const m = /^DSHREMOTE\|(.+?)\|(.*)$/.exec(payload);
	assert.ok(m, "应能被 App 端扫码正则解析");
	assert.equal(m[1], "http://192.168.1.5:3082/m");
	assert.equal(m[2], "abc");
});

test("二维码图片地址仍使用挂载路径前缀", () => {
	// 组件里 qrSrc = mount + "/qr.png?text=..."，挂载路径不得变成 /m/m
	const mount = String("/m").replace(/\/+$/, "");
	assert.equal(`${mount}/qr.png?text=x`, "/m/qr.png?text=x");
});
