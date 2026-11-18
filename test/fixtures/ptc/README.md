# PTC 子调用真实事件夹具

issue #68 的夹具目录：保存**真实捕获**（captured，非源码派生）的 `tool/ptc-dispatch-start` /
`tool/ptc-dispatch` 会话事件，用于服务端投影（T3）与 App 子调用树（T4）的测试。

捕获日期：2026-11-10（UTC）。捕获环境：dsh `0.2.2-rc.1`、Node `v24.19.0`、Linux、
headless 内置 profile、模型 `deepseek-official/deepseek-flash`。

## 文件

| 文件 | 内容 |
| --- | --- |
| `dispatch-events.json` | 6 条 PTC 事件：3 组 `tool/ptc-dispatch-start` + `tool/ptc-dispatch`（read 成功、bash 成功、read 失败） |
| `outer-tool-events.json` | 2 条外层原生事件（`tool/call` 与 `tool/result`，`name: "run_code"`），仅作上下文；**不是** PTC 投影输入 |
| `README.md` | 本文件：来源、命令、字段形状、脱敏与再现步骤 |

两个 JSON 都是纯 JSON，可直接 `readFileSync` / `JSON.parse`（或 Node 24 的
`import … with { type: 'json' }`）。事件保留捕获时的 `type` / `seq` / `time` / `data` 外层结构，
`data` 与内核 `agent.session.append` 的载荷逐字段一致（仅做第 9 节所述路径替换）。

## 1. 为什么需要隔离环境 + executor patch

headless 内置 profile 默认挂载 `@deepseek-ai/dsh-tool-executor-native`，并
`disabled: true` 关掉 `@deepseek-ai/dsh-tool-executor-ptc`（`dsh --profile headless --dump-config`
可复核）。该状态下模型看不到 `run_code`，内核也不会发射 `tool/ptc-dispatch*`。因此捕获时用一次性
`--patch` overlay 反转两者：

```yaml
# /tmp/ptc-fixture-dsh/ptc.patch.yml
- id: tool-executor-native
  disabled: true
- id: tool-executor-ptc
  disabled: false
```

其余环境均隔离在一次性目录，**没有**写入共享 `~/.dsh/mobile-remote`、没有触碰 3080 宿主：

- `DSH_HOME=/tmp/ptc-fixture-dsh`（全新目录即可；headless 是内置模板名，不能作为 `--from-default-profile` 的目标，全新 DSH_HOME 会自动使用内置模板，无需该参数）
- 工作目录 `/tmp/ptc-fixture-work`（内含一份 5 行 `README.md`）
- API key 来自一次性 `/tmp/ptc-fixture-work/.env`（`DEEPSEEK_API_KEY=…`）。headless profile
  内置的 credentials 服务是禁用的，不会读共享 `~/.dsh/.credentials.yaml`；`.env` 不落仓库、捕获后即删。

## 2. 捕获场景（prompt 原文）

```text
Call the `run_code` tool exactly once. Its program must do three things, then return a small JSON summary:
1) await tools.read({ file_path: "README.md", limit: 3 }) — read the relative path exactly as written;
2) await tools.bash({ command: "echo ptc-fixture-ok", description: "Print the fixture marker" });
3) in a try/catch, await tools.read({ file_path: "ptc-missing-file.txt", limit: 3 }) — this file does not exist; catch the error and record String(e && e.message || e) as errorMessage.
Do not use any other tool. Do not write or modify any file. Do not retry the failing read. After the run, return the JSON summary of the three outcomes (readOk, bashOk, errorMessage).
```

对应期望结果：`read` 成功、`bash` 成功（`ptc-fixture-ok`）、`read` 失败（`FsError/FS_NOT_FOUND`）。
注意 `bash` 工具要求 `description` 参数；缺省会得到 `ToolArgsError/INVALID_ARGS`（未收录进夹具）。

## 3. 捕获命令

```bash
# 1) 一次性工作目录与输入
mkdir -p /tmp/ptc-fixture-dsh /tmp/ptc-fixture-work
printf '# PTC fixture workspace\n\nLine two of the fixture README.\nLine three of the fixture README.\nLine four of the fixture README.\n' > /tmp/ptc-fixture-work/README.md
# 2) API key（隔离环境；不要提交）
printf 'DEEPSEEK_API_KEY=%s\n' "$DEEPSEEK_API_KEY" > /tmp/ptc-fixture-work/.env   # chmod 600
# 3) executor patch overlay（见第 1 节）写入 /tmp/ptc-fixture-dsh/ptc.patch.yml
# 4) 真实 headless 运行（prompt 见第 2 节，存为 /tmp/ptc-fixture-work/prompt.txt）
cd /tmp/ptc-fixture-work && \
DSH_HOME=/tmp/ptc-fixture-dsh \
DSH_PERMISSION_MODE=danger-full-access \
NO_PROXY=127.0.0.1,localhost,::1 \
dsh --profile headless --patch /tmp/ptc-fixture-dsh/ptc.patch.yml \
    --json --approval-policy never "$(cat prompt.txt)"
```

本机 `workspace-write` 沙箱后端不可用（`sandbox-unavailable`），所以捕获时把权限模式提到
`danger-full-access`；程序本身只读相对文件、跑 `echo`，且工作目录是一次性 `/tmp` 目录。

本次捕获的会话目录：
`/tmp/ptc-fixture-dsh/sessions/--tmp-ptc-fixture-work--/session-c6811deb-71d8-47b2-bb82-43ae56450e36/`。

## 4. 事件抽取

会话日志 `session.v4.jsonl.zstd` 是**多个独立 zstd frame 的拼接**（每次 append 一帧）。Node 的
`zlib.zstdDecompressSync` 只解第一帧，必须按 Zstandard 帧结构先切帧再逐帧解压：

```js
import { readFileSync, writeFileSync } from 'node:fs';
import { zstdDecompressSync } from 'node:zlib';

const ZSTD_MAGIC = 4247762216;
function scanZstdFrames(buffer) {           // 只扫描结构，不解压
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`bad magic at ${offset}`);
    offset += 4;
    const descriptor = buffer.readUInt8(offset); offset += 1;
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
    offset += (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    for (;;) {
      const blockHeader = buffer.readUIntLE(offset, 3); offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      offset += blockType === 1 ? 1 : blockSize;
      if (lastBlock) break;
    }
    if (checksum) offset += 4;
    frames.push({ start, end: offset });
  }
  return frames;
}

const file = process.argv[2];
const buf = readFileSync(file);
const jsonl = Buffer.concat(scanZstdFrames(buf).map((f) => zstdDecompressSync(buf.subarray(f.start, f.end))));
writeFileSync(process.argv[3], jsonl);
```

然后过滤 `type` 以 `tool/ptc-dispatch` 开头的事件（本会话为 `seq` 19–26，共 6 条），并对工作目录
绝对路径做第 9 节的替换。外层 `tool/call`（`seq` 18）与 `tool/result`（`seq` 27）单独收录。

## 5. 捕获到的事件序列

| seq | type | 说明 |
| --- | --- | --- |
| 18 | `tool/call` | 外层 `run_code`（`callId: call_00_ET_F0UF9gYXReFLq88FyAFg8010`），见 `outer-tool-events.json` |
| 19 | `tool/ptc-dispatch-start` | `read` `README.md` `limit: 3` |
| 20 | `tool/ptc-dispatch` | 同上，`isError: false`，含 `content` + `meta` |
| 21 | `tool/ptc-dispatch-start` | `bash` `echo ptc-fixture-ok` |
| 22–23 | `job/registered` / `job/settled` | bash 执行期间的 job 事件（**不属于** PTC，未收录） |
| 24 | `tool/ptc-dispatch` | bash 结果，`isError: false`，含 `content` + `meta.cwd` |
| 25 | `tool/ptc-dispatch-start` | `read` `ptc-missing-file.txt` |
| 26 | `tool/ptc-dispatch` | 同上，`isError: true`，含 `error` + `content`，无 `meta` |
| 27 | `tool/result` | 外层 `run_code` 结果，见 `outer-tool-events.json` |

结论：**start 与 result 不保证相邻**（bash 的 result 被 job 事件隔开），消费方必须按 `subCallId`
关联，不能依赖 seq 连续或相邻。（内核并发调度顺序见 `ptc.js` 的 pendingQueue/commit 车道。）

## 6. 真实字段形状（与内核 `ptc.js` 发射点一致）

`tool/ptc-dispatch-start` 的 `data`：

| 字段 | 类型 | 备注 |
| --- | --- | --- |
| `rootCallId` | string | 外层 `run_code` 调用的 callId；本夹具 `call_00_ET_F0UF9gYXReFLq88FyAFg8010` |
| `parentCallId` | string | 发起子调用的工具调用 id；顶层 PTC 等于外层 `run_code` 的 callId |
| `subCallId` | string | `<parentCallId>:ptc:<n>`，`n` 从 1 递增 |
| `name` | string | 子工具名，如 `read` / `bash` |
| `arguments` | object | 内核的 sibling JSON parse 结果（模型实参的快照），不含 `description` 之外的控制参数 |

`tool/ptc-dispatch` 在 start 字段之外追加：

| 字段 | 类型 | 备注 |
| --- | --- | --- |
| `isError` | boolean | 成功也显式下发 `false` |
| `content` | `ContentBlock[]` | **不是字符串**。本夹具均为 `[{ "type": "text", "text": "…" }]`；内核允许 image 块（`ptc.js` 对 `block.type === 'image'` 有专门分支），本夹具未覆盖 |
| `meta` | object（可选） | 工具私有结构化结果。`read`：`{ path, offset, lines: [{number,text}], totalLines, lang }`；`bash`：`{ cwd }`；失败结果无 `meta` |
| `error` | object（可选） | 仅失败时出现：`{ name, code }`，本夹具为 `{ "name": "FsError", "code": "FS_NOT_FOUND" }`；失败结果的 `content` 是 `[{type:'text', text:'Error: …'}]` |

其他观察：

- 成功结果的 `content` 文本是工具面向模型的文本（read 含 `<path>/<type>/<content>` 包装），
  `meta` 才是结构化数据；两者都可能含工作目录绝对路径（夹具已替换）。
- 本夹具里 `parentCallId === rootCallId`（顶层 run_code）。子代理内再发生的 PTC 会有更深的
  parent 关系，本夹具未覆盖。

## 7. 与 `tool/call` / `tool/result` 的关系

`outer-tool-events.json` 收录同一会话的外层原生事件：

- `tool/call.data.arguments` 是 JSON **字符串**（`{"description":…,"code":…}`），与 PTC 子调用的
  `arguments`（对象）形状不同。
- `tool/result.data.message.toolCallId` 等于 `rootCallId`，可用于把子调用挂到根工具卡。
- 外层 `tool/result` 的内容只含程序返回值摘要，不含子调用明细——这正是 issue #68 要补的投影。

## 8. 消费这些夹具时的注意点

- `seq` 是会话全局序号，本夹具为 19–26，但生产事件之间可能穿插其他类型，**不要假设连续**。
- 按 `subCallId` 关联 start 与 result；同一 `subCallId` 的 result 应原地更新，不应新增节点。
- 不要依赖 `arguments` 内容做渲染或安全摘要（可能含敏感参数），也不要原样展示 `meta`。
- 失败事件的 `content` 文本可能包含绝对路径（本夹具已把工作目录替换为 `<workspace>`），投影层
  必须安全截断/白名单，不能直接把 `content` 原文下发。
- 真实夹具未覆盖：图片块、嵌套 PTC（subagent）、50 条截断、重复 result、迟到 result、orphan、
  自环/祖先环。这些需在 T3/T4 单测里构造合成事件，语义以 issue #68 契约（`/tmp/issue68-contract.md`）
  与内核 `ptc.js` 为准。

## 9. 脱敏与完整性

- 唯一替换：工作目录绝对路径（`/tmp/ptc-fixture-work`）→ `<workspace>`。`dispatch-events.json`
  4 处、`outer-tool-events.json` 1 处；`seq`/`time`/id/`content`/`meta`/`error` 其余字段保持捕获原样。
- 不含 API key、`sk-` 前缀、`/home/`、`/root`、`~` 或 DSH 会话宿主路径；JSON 内也不引用捕获机的
  `/tmp` 路径（完整命令见本 README）。
- 来源校验：原始压缩会话文件 `session.v4.jsonl.zstd` SHA-256
  `758ef02acb59f8e3230c262d32a6ef1a5e4e0b94ad415a6e6a2a7c88536e8ae6`；解码后 JSONL SHA-256
  `6d3906cc3f11f45eeb69bbf5886b1a9bd64a94c2f1238ba480104fad6f4be30b`；解码后共 35 条事件。
- 夹具 `origin` 字段固定为 `captured`，可据此把「真实捕获」与「源码派生」区分开。

## 10. 重新捕获（可选）

1. 按第 3 节创建 `/tmp/ptc-fixture-dsh`、`/tmp/ptc-fixture-work`、`README.md`、`.env`、patch、prompt。
2. 执行第 3 节命令；确认最后 `final` 文本包含 `"readOk": true` 与失败 read 的错误信息。
3. 找到新会话目录，用第 4 节的切帧脚本解码为 JSONL。
4. 过滤 `tool/ptc-dispatch*` 与 `tool/call`/`tool/result` 事件，替换工作目录路径后写入本目录；
   更新本 README 的日期、sha256、seq 表与第 9 节替换处数。
5. 复查无密钥、无 home 路径：`grep -nE '/home/|/root|sk-|DEEPSEEK' test/fixtures/ptc/*.json` 应无命中。
