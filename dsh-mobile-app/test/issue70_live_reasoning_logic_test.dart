// issue #70（ADR 0027 §2 实时态）：流式思考缓冲 / 最近行预览 / 落定排序键继承的纯逻辑单测。
//
// 这些用例不依赖 Flutter widget：LiveReasoningBuffer、latestReasoningLinePreview 与
// TurnProcessTracker 的「同 step 仅一条 / 继承首个 delta seq」都是可单测的纯投影。

import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter_test/flutter_test.dart';

ChatEvent _event(int seq, String type, Map<String, dynamic> data) =>
    ChatEvent(seq: seq, type: type, data: data);

void main() {
  group('latestReasoningLinePreview：取最近一个非空行', () {
    test('多行取最后一行（忽略行尾空白与空行）', () {
      expect(
        latestReasoningLinePreview('first line\nsecond line\n'),
        'second line',
      );
      expect(latestReasoningLinePreview('a\n\n  b  \n\n'), 'b');
      expect(latestReasoningLinePreview('  only  '), 'only');
    });

    test('空文本 / 全空白 → 空串', () {
      expect(latestReasoningLinePreview(''), '');
      expect(latestReasoningLinePreview('   \n\t\n'), '');
    });

    test('超过 120 字符截断并补一个省略号（总长 121）', () {
      final long = 'A' * 130;
      final preview = latestReasoningLinePreview(long);
      expect(preview, '${'A' * 120}…');
      expect(preview.length, 121);
      // 恰好 120 不截断
      expect(latestReasoningLinePreview('B' * 120), 'B' * 120);
    });

    test('最近行才是长行时仍按最近行截断', () {
      final text = 'short first\n${'C' * 130}';
      expect(latestReasoningLinePreview(text), '${'C' * 120}…');
    });
  });

  group('LiveReasoningBuffer：按 (turn, step) 缓冲、结构变化与 tombstone', () {
    setUp(LiveProcessCounters.reset);

    test('首次 append 是结构变化；同键后续只增长文本', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, 1, 'a', seq: 10), isTrue);
      expect(LiveProcessCounters.appends, 1);
      expect(LiveProcessCounters.structuralChanges, 1);
      expect(buffer.append(1, 1, 'b', seq: 11), isFalse);
      expect(LiveProcessCounters.structuralChanges, 1);
      final live = buffer.current!;
      expect(live.turn, 1);
      expect(live.step, 1);
      expect(live.text, 'ab');
      expect(live.chars, 2);
      expect(live.firstSeq, 10);
      expect(buffer.firstSeqOf(1, 1), 10);
      expect(buffer.firstSeqOf(1, 2), isNull);
    });

    test('step 切换：关闭旧键、只保留新 step；更小 step 的迟到 chunk 丢弃', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, 1, 'old', seq: 10), isTrue);
      expect(buffer.append(1, 2, 'new', seq: 20), isTrue);
      expect(buffer.current!.step, 2);
      expect(buffer.current!.text, 'new');
      // 迟到的 step1 chunk（更小 step）→ 丢弃且不增长新 step 文本
      expect(buffer.append(1, 1, 'late', seq: 21), isFalse);
      expect(buffer.current!.text, 'new');
    });

    test('step 缺失：退化键可被明确 step 取代，迟到退化 chunk 不覆盖已知 step', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, null, 'legacy', seq: 10), isTrue);
      expect(buffer.current!.step, isNull);
      expect(buffer.append(1, 2, 'typed', seq: 11), isTrue);
      expect(buffer.current!.step, 2);
      expect(buffer.current!.text, 'typed');
      expect(buffer.append(1, null, 'late', seq: 12), isFalse);
      expect(buffer.current!.text, 'typed');
    });

    test('跨轮：新轮首现关闭更早轮的条目；更早轮迟到 chunk 丢弃', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, 1, 'turn1', seq: 10), isTrue);
      expect(buffer.append(2, 1, 'turn2', seq: 20), isTrue);
      expect(buffer.current!.turn, 2);
      expect(buffer.append(1, 1, 'late-turn1', seq: 21), isFalse);
      expect(buffer.current!.turn, 2);
    });

    test('closeStep：关闭 step<=settledStep 的键并写 tombstone，之后更大 step 仍可流式', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, 1, 'one', seq: 10), isTrue);
      expect(buffer.closeStep(1, 1), isTrue);
      expect(buffer.current, isNull);
      // 同 step 的迟到 chunk 不复活
      expect(buffer.append(1, 1, 'late', seq: 11), isFalse);
      expect(buffer.current, isNull);
      // 下一 step 正常流式
      expect(buffer.append(1, 2, 'two', seq: 12), isTrue);
      expect(buffer.current!.step, 2);
    });

    test('closeStep(step=null)：关闭该轮全部活动键，后续 numeric step 仍可流式', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, 1, 'one', seq: 10), isTrue);
      expect(buffer.closeStep(1, null), isTrue);
      expect(buffer.current, isNull);
      expect(buffer.append(1, 1, 'late-same-step', seq: 11), isFalse);
      expect(buffer.append(1, 2, 'next-step', seq: 12), isTrue);
    });

    test('closeTurn：整轮关闭，任意 step 的迟到 chunk 都丢弃；clear 清空关闭集合', () {
      final buffer = LiveReasoningBuffer();
      expect(buffer.append(1, 1, 'one', seq: 10), isTrue);
      expect(buffer.closeTurn(1), isTrue);
      expect(buffer.current, isNull);
      expect(buffer.append(1, 3, 'late', seq: 11), isFalse);
      expect(buffer.append(1, null, 'late-null', seq: 12), isFalse);

      buffer.clear();
      expect(buffer.append(1, 1, 'fresh', seq: 13), isTrue);
    });

    test('pruneBefore：丢弃 firstSeq 早于裁剪点的条目', () {
      final buffer = LiveReasoningBuffer();
      buffer.append(2, 1, 'keep-me', seq: 30);
      buffer.pruneBefore(20);
      expect(buffer.current!.text, 'keep-me');
      buffer.pruneBefore(31);
      expect(buffer.current, isNull);
    });

    test('trimClosedTurns：关闭集合只保留最近两轮', () {
      final buffer = LiveReasoningBuffer();
      buffer.closeTurn(1);
      buffer.closeTurn(2);
      buffer.trimClosedTurns(3); // 保留 >= 2
      // turn1 的 tombstone 已回收（有界），turn2 仍在。
      expect(buffer.append(2, 1, 'late-t2', seq: 20), isFalse);
      expect(buffer.current, isNull);
    });

    test('current 取最大轮次的最大 step', () {
      final buffer = LiveReasoningBuffer();
      buffer.append(1, 1, 'a', seq: 10);
      buffer.append(2, 1, 'b', seq: 20);
      buffer.append(2, 3, 'c', seq: 30);
      expect(buffer.current!.turn, 2);
      expect(buffer.current!.step, 3);
      expect(buffer.current!.text, 'c');
    });
  });

  group('TurnProcessTracker：落定排序键继承与同 step 去重', () {
    test('历史回放（无 noteReasoningStart）行为不变：行 seq = message seq', () {
      final tracker = TurnProcessTracker()
        ..observe(_event(1, 'turn/start', {'turn': 1}))
        ..observe(_event(
          5,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'r', 'reasoningChars': 1},
        ));
      final rows = tracker.build().single.rows;
      expect(rows, hasLength(1));
      expect(rows.single.seq, 5);
    });

    test('noteReasoningStart：行排序键继承首个 delta seq（min(firstDelta, messageSeq)）', () {
      final tracker = TurnProcessTracker()
        ..observe(_event(1, 'turn/start', {'turn': 1}))
        ..noteReasoningStart(1, 1, 2)
        ..observe(_event(
          5,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'r', 'reasoningChars': 1},
        ));
      final rows = tracker.build().single.rows;
      expect(rows.single.seq, 2, reason: '落定后与 provisional 使用同一排序键，避免跳位');
    });

    test('首 delta seq 晚于 message seq 时取 message seq（不把行排到未来）', () {
      final tracker = TurnProcessTracker()
        ..observe(_event(1, 'turn/start', {'turn': 1}))
        ..noteReasoningStart(1, 1, 9)
        ..observe(_event(
          5,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'r', 'reasoningChars': 1},
        ));
      expect(tracker.build().single.rows.single.seq, 5);
    });

    test('同一 (turn, step) 多条 reasoning 消息：只保留 seq 最大的一条', () {
      final tracker = TurnProcessTracker()
        ..observe(_event(1, 'turn/start', {'turn': 1}))
        ..observe(_event(
          5,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'first', 'reasoningChars': 5},
        ))
        ..observe(_event(
          8,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'second', 'reasoningChars': 6},
        ));
      final rows = tracker.build().single.rows;
      expect(rows, hasLength(1));
      expect(rows.single.seq, 8);
      expect(rows.single.reasoning, 'second');
    });

    test('不同 step 各自保留一条', () {
      final tracker = TurnProcessTracker()
        ..observe(_event(1, 'turn/start', {'turn': 1}))
        ..observe(_event(
          5,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'r1', 'reasoningChars': 2},
        ))
        ..observe(_event(
          8,
          'assistant/message',
          {'turn': 1, 'step': 2, 'reasoning': 'r2', 'reasoningChars': 2},
        ));
      expect(tracker.build().single.rows, hasLength(2));
    });

    test('dropReasoningStart：轮末丢弃后不再继承（无悬挂记录）', () {
      final tracker = TurnProcessTracker()
        ..observe(_event(1, 'turn/start', {'turn': 1}))
        ..noteReasoningStart(1, 1, 2)
        ..dropReasoningStart(1)
        ..observe(_event(
          5,
          'assistant/message',
          {'turn': 1, 'step': 1, 'reasoning': 'r', 'reasoningChars': 1},
        ));
      expect(tracker.build().single.rows.single.seq, 5);
    });

    test('reset 清空首 delta 记录', () {
      final tracker = TurnProcessTracker()..noteReasoningStart(1, 1, 2);
      tracker.reset();
      tracker.observe(_event(1, 'turn/start', {'turn': 1}));
      tracker.observe(_event(
        5,
        'assistant/message',
        {'turn': 1, 'step': 1, 'reasoning': 'r', 'reasoningChars': 1},
      ));
      expect(tracker.build().single.rows.single.seq, 5);
    });
  });
}
