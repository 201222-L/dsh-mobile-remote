// issue #99：compaction surface replay envelope（surfaceOp/sourceEventSeqs）必须随
// /history 与 SSE 共用的 summarizeEvent 摘要下发；旧客户端忽略新增顶层字段。
import test from "node:test";
import assert from "node:assert/strict";
import { summarizeEvent, surfaceWireFields } from "../lib/index.js";

const replay = {
  seq: 13283,
  type: "tool/result",
  time: 1794490887536,
  data: {
    turn: 148, step: 1,
    message: {
      role: "tool",
      source: { kind: "tool", callId: "call_00_mx03" },
      toolCallId: "call_00_mx03",
      content: [{ type: "text", text: "note 2312" }],
    },
  },
  sourceEventSeqs: [9142],
  surfaceOp: { op: "replace", startSeq: 9142, endSeq: 9142 },
};

test("issue #99: summarizeEvent 透传 replace surfaceOp/sourceEventSeqs", () => {
  const summary = summarizeEvent(replay);
  assert.equal(summary.seq, 13283);
  assert.equal(summary.type, "tool/result");
  assert.equal(summary.data.callId, "call_00_mx03");
  assert.deepEqual(summary.surfaceOp, { op: "replace", startSeq: 9142, endSeq: 9142 });
  assert.deepEqual(summary.sourceEventSeqs, [9142]);
});

test("issue #99: append/无 envelope 事件不凭空产生 surface 字段", () => {
  const append = summarizeEvent({ seq: 1, type: "tool/result", data: {}, surfaceOp: { op: "append", startSeq: 1, endSeq: 1 } });
  assert.deepEqual(append.surfaceOp, { op: "append", startSeq: 1, endSeq: 1 });
  const plain = summarizeEvent({ seq: 2, type: "assistant/message", data: { message: { content: [] } } });
  assert.equal("surfaceOp" in plain, false);
  assert.equal("sourceEventSeqs" in plain, false);
});

test("issue #99: surface 字段严格校验——仅非负 safe integer，禁止 Number 强转", () => {
  // 合法：去重 + 正序；startSeq<=endSeq；source < 当前 seq。
  assert.deepEqual(
    surfaceWireFields({
      seq: 100,
      surfaceOp: { op: "replace", startSeq: 1, endSeq: 1 },
      sourceEventSeqs: [20, 2, 20, 3],
    }),
    {
      surfaceOp: { op: "replace", startSeq: 1, endSeq: 1 },
      sourceEventSeqs: [2, 3, 20],
    },
  );
  // append 无 source 也允许。
  assert.deepEqual(
    surfaceWireFields({ seq: 10, surfaceOp: { op: "append", startSeq: 10, endSeq: 10 } }),
    { surfaceOp: { op: "append", startSeq: 10, endSeq: 10 } },
  );
  // 无 envelope 字段 → 空对象（不凭空产生 surface）。
  assert.deepEqual(surfaceWireFields({ seq: 1 }), {});
  assert.deepEqual(surfaceWireFields(null), {});
});

test("issue #99: surfaceOp union——真实字符串 append 与对象 append/replace", () => {
  // 真实 DSH 形状：字符串 append + sourceEventSeqs。
  assert.deepEqual(
    surfaceWireFields({ seq: 10, surfaceOp: "append", sourceEventSeqs: [3] }),
    { surfaceOp: "append", sourceEventSeqs: [3] },
  );
  // 对象 append 可省略 start/end；带则规范化。
  assert.deepEqual(
    surfaceWireFields({ seq: 10, surfaceOp: { op: "append" } }),
    { surfaceOp: { op: "append" } },
  );
  assert.deepEqual(
    surfaceWireFields({ seq: 10, surfaceOp: { op: "append", startSeq: 8, endSeq: 9 } }),
    { surfaceOp: { op: "append", startSeq: 8, endSeq: 9 } },
  );
  // 对象 replace 仍是现有形状。
  assert.deepEqual(
    surfaceWireFields({ seq: 10, surfaceOp: { op: "replace", startSeq: 9, endSeq: 9 } }),
    { surfaceOp: { op: "replace", startSeq: 9, endSeq: 9 } },
  );
});

test("issue #99: surfaceOp union 非法值整组丢弃（字符串/对象 append 含 source）", () => {
  for (const surfaceOp of ["replace", "APPEND", "", "append ", true, false, null, 1, [], ["append"]]) {
    assert.deepEqual(
      surfaceWireFields({ seq: 10, surfaceOp, sourceEventSeqs: [3] }),
      {},
      JSON.stringify(surfaceOp),
    );
  }
  for (const surfaceOp of [
    { op: "append", startSeq: 3 }, // 只有 start
    { op: "append", endSeq: 3 }, // 只有 end
    { op: "append", startSeq: 9, endSeq: 3 }, // 倒序
    { op: "append", startSeq: null, endSeq: 3 },
    { op: "append", startSeq: "3", endSeq: "4" },
    { op: "append", startSeq: null, endSeq: null },
    { op: "append", startSeq: null },
    { op: "other", startSeq: 3, endSeq: 3 },
  ]) {
    assert.deepEqual(surfaceWireFields({ seq: 10, surfaceOp }), {}, JSON.stringify(surfaceOp));
  }
  // append + 非法 source 也必须整组丢弃。
  assert.deepEqual(
    surfaceWireFields({ seq: 10, surfaceOp: "append", sourceEventSeqs: [3, 10] }),
    {},
  );
  // replace + 混合坏 source 也整组丢弃，不能留下 replace。
  assert.deepEqual(
    surfaceWireFields({
      seq: 10,
      surfaceOp: { op: "replace", startSeq: 3, endSeq: 3 },
      sourceEventSeqs: [3, 10],
    }),
    {},
  );
  // 显式 null 与缺失不同：显式 null 一律非法。
  assert.deepEqual(surfaceWireFields({ seq: 10, surfaceOp: null }), {});
  assert.deepEqual(surfaceWireFields({ seq: 10, sourceEventSeqs: null }), {});
  assert.deepEqual(surfaceWireFields({ seq: 10, surfaceOp: "append", sourceEventSeqs: null }), {});
  // 仅 source（无 surfaceOp 键）合法；缺失 surfaceOp ≠ 非法。
  assert.deepEqual(surfaceWireFields({ seq: 10, sourceEventSeqs: [3] }), { sourceEventSeqs: [3] });
});

test("issue #99: surfaceOp 非法时整个字段省略（null/false/''/true/字符串/负数/倒序）", () => {
  const invalidOps = [
    null,
    false,
    "",
    "replace",
    [],
    { op: "", startSeq: 1, endSeq: 1 },
    { op: "   ", startSeq: 1, endSeq: 1 },
    { op: "replace", startSeq: null, endSeq: 1 },
    { op: "replace", startSeq: false, endSeq: 1 },
    { op: "replace", startSeq: "", endSeq: 1 },
    { op: "replace", startSeq: true, endSeq: 1 },
    { op: "replace", startSeq: "9142", endSeq: 9142 },
    { op: "replace", startSeq: -1, endSeq: 1 },
    { op: "replace", startSeq: 1, endSeq: 1.5 },
    { op: "replace", startSeq: 5, endSeq: 1 },
  ];
  for (const surfaceOp of invalidOps) {
    assert.deepEqual(surfaceWireFields({ seq: 10, surfaceOp }), {}, JSON.stringify(surfaceOp));
    assert.deepEqual(
      Object.keys(summarizeEvent({ seq: 10, type: "tool/result", data: {}, surfaceOp })).includes("surfaceOp"),
      false,
    );
  }
});

test("issue #99: sourceEventSeqs 非法/混入/超长/不早于当前 seq 时整体省略", () => {
  const invalidSources = [
    null,
    false,
    "",
    true,
    [],
    [-1],
    [10],
    [11],
    [1, "2"],
    [1, true],
    [1, null],
    [1, 2, 2.5],
    [1, -2],
    [3, 8, 10],
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
    [1, 2, "3", 4],
  ];
  for (const sourceEventSeqs of invalidSources) {
    assert.deepEqual(
      surfaceWireFields({ seq: 10, sourceEventSeqs }),
      {},
      JSON.stringify(sourceEventSeqs),
    );
  }
  // 超长（65）即使都合法也拒绝。
  assert.deepEqual(
    surfaceWireFields({ seq: 1000, sourceEventSeqs: Array.from({ length: 65 }, (_, i) => i) }),
    {},
  );
  // 64 项合法可通过。
  assert.deepEqual(
    surfaceWireFields({ seq: 1000, sourceEventSeqs: Array.from({ length: 64 }, (_, i) => i) }).sourceEventSeqs.length,
    64,
  );
  // source 缺当前 seq（无法证明严格早于）→ 省略。
  assert.deepEqual(surfaceWireFields({ sourceEventSeqs: [1] }), {});
});

test("issue #99: summarizeEvent 对坏 envelope 不解释为 replace（history/SSE 同函数）", () => {
  const bad = summarizeEvent({
    seq: 13283,
    type: "tool/result",
    data: { turn: 148, step: 1 },
    sourceEventSeqs: [9142],
    surfaceOp: { op: "replace", startSeq: "9142", endSeq: 9142 },
  });
  assert.equal("surfaceOp" in bad, false);
  assert.equal("sourceEventSeqs" in bad, false);

  const mixed = summarizeEvent({
    seq: 13283,
    type: "tool/result",
    data: {},
    sourceEventSeqs: [9142, null],
    surfaceOp: { op: "replace", startSeq: 9142, endSeq: 9142 },
  });
  assert.equal(mixed.seq, 13283);
  assert.equal(mixed.type, "tool/result");
  assert.equal("surfaceOp" in mixed, false);
  assert.equal("sourceEventSeqs" in mixed, false);
});
