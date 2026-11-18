// issue #52（ADR 0027 §2）：轮次过程折叠与展示模式的纯规则测试。
//
// 这里锁的是**行为语义**，不是像素：三层折叠、强制展开三条件、两档收起时机、
// 用时只认服务端 time、单轮 >50 行分批、按 step 派生过程组。

import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter_test/flutter_test.dart';

ChatEvent ev(
  int seq,
  String type, [
  Map<String, dynamic>? data,
  int? time,
]) =>
    ChatEvent(seq: seq, type: type, data: data, time: time);

TurnProcessTracker trackerOf(List<ChatEvent> events) {
  final tracker = TurnProcessTracker();
  for (final event in events) {
    tracker.observe(event);
  }
  return tracker;
}

/// 一轮完整对话：turn/start → 思考 + 两次工具 → 最终回答 → turn/end。
List<ChatEvent> oneTurn({
  int turn = 1,
  String? endKind = 'completed',
  int startTime = 1000,
  int endTime = 4500,
  bool includeTime = true,
  List<int>? extraUserSeqs,
}) {
  final events = <ChatEvent>[
    ev(1, 'turn/start', {'turn': turn}, includeTime ? startTime : null),
    ev(2, 'assistant/message', {
      'turn': turn,
      'step': 1,
      'reasoning': '先看目录结构\n再看看测试',
      'reasoningChars': 16,
      'text': '',
    }, includeTime ? startTime + 500 : null),
    ev(3, 'tool/call', {
      'turn': turn,
      'step': 1,
      'callId': 'call-a',
      'name': 'shell',
      'arguments': 'ls',
    }, includeTime ? startTime + 800 : null),
    ev(4, 'tool/result', {
      'turn': turn,
      'step': 1,
      'callId': 'call-a',
      'name': 'shell',
      'text': 'ok',
    }, includeTime ? startTime + 1200 : null),
    ev(5, 'tool/call', {
      'turn': turn,
      'step': 2,
      'callId': 'call-b',
      'name': 'read_file',
      'arguments': '{}',
    }, includeTime ? startTime + 1500 : null),
    ev(6, 'tool/result', {
      'turn': turn,
      'step': 2,
      'callId': 'call-b',
      'name': 'read_file',
      'text': 'content',
    }, includeTime ? startTime + 2000 : null),
    ev(7, 'assistant/message', {
      'turn': turn,
      'step': 2,
      'text': '最终回答',
    }, includeTime ? startTime + 3000 : null),
    if (includeTime || endKind != null)
      ev(8, 'turn/end', {
        'turn': turn,
        if (endKind != null) 'reason': {'kind': endKind},
      }, includeTime ? endTime : null),
    for (final seq in extraUserSeqs ?? const <int>[]) ev(seq, 'user/message', {'text': '插话'}),
  ];
  return events;
}

void main() {
  group('过程组派生（按 step；缺 step 退化为整轮一组）', () {
    test('同一轮按 step 聚合成过程组，组内按 seq 排序', () {
      final turns = trackerOf(oneTurn()).build();
      expect(turns, hasLength(1));
      final turn = turns.single;
      expect(turn.groups.map((g) => g.step), [1, 2]);
      expect(turn.groups.first.rows.map((r) => r.kind),
          [ProcessRowKind.reasoning, ProcessRowKind.tool]);
      expect(turn.groups.first.rows.last.callId, 'call-a');
      expect(turn.groups.last.rows.map((r) => r.callId), ['call-b']);
      expect(turn.toolCount, 2);
      expect(turn.rowCount, 3);
    });

    test('缺 step 的事件退化为整轮一组', () {
      final turns = trackerOf([
        ev(1, 'turn/start', {'turn': 3}),
        ev(2, 'tool/call', {'turn': 3, 'callId': 'c1', 'name': 'shell'}),
        ev(3, 'tool/result', {'turn': 3, 'callId': 'c1', 'text': 'ok'}),
        ev(4, 'turn/end', {'turn': 3, 'reason': {'kind': 'completed'}}),
      ]).build();
      expect(turns.single.groups, hasLength(1));
      expect(turns.single.groups.single.step, isNull);
      expect(turns.single.groups.single.toolCount, 1);
    });

    test('历史倒序 / 分页重叠到达也能收敛成同一结构（顺序无关）', () {
      final events = oneTurn();
      final forward = trackerOf(events).build();
      final reversed = trackerOf(events.reversed.toList()).build();
      // 重叠观察（同一批事件再来一遍）不得重复过程行。
      final doubled = trackerOf([...events, ...events]).build();
      expect(forward.single.groups.length, reversed.single.groups.length);
      expect(forward.single.rowCount, reversed.single.rowCount);
      expect(doubled.single.rowCount, forward.single.rowCount);
      expect(doubled.single.toolCount, 2);
    });

    test('工具调用进行中 → 组抬头显示「正在调用工具…」，完成 → 「N 次工具调用」', () {
      final running = trackerOf([
        ev(1, 'turn/start', {'turn': 1}),
        ev(2, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'shell'}),
      ]).build().single;
      expect(running.groups.single.running, isTrue);
      expect(processGroupHeader(running.groups.single, running: true), '正在调用工具…');
      final done = trackerOf(oneTurn()).build().single;
      expect(done.groups.first.running, isFalse);
      expect(processGroupHeader(done.groups.first, running: false), '1 次工具调用');
    });
  });

  group('强制展开（不看策略）', () {
    TurnProcess turnWith({
      String? endKind = 'completed',
      bool ended = true,
      List<int> steerSeqs = const [],
    }) {
      final events = <ChatEvent>[
        ev(1, 'turn/start', {'turn': 1}),
        // 提示词：事件序里 turn/start 之后的第一条真人 user/message（不算插话）。
        ev(2, 'user/message', {'text': '提示词', 'sourceKind': 'user'}),
        ev(3, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'shell'}),
        ev(4, 'tool/result', {'turn': 1, 'step': 1, 'callId': 'c1', 'text': 'ok'}),
        for (final seq in steerSeqs)
          ev(seq, 'user/message', {'text': '插话', 'sourceKind': 'user'}),
        if (ended) ev(9, 'turn/end', {'turn': 1, 'reason': {'kind': endKind}}),
      ];
      return trackerOf(events).build().single;
    }

    test('轮次未结束 → 强制展开', () {
      final turn = turnWith(ended: false, endKind: null);
      expect(turn.forceExpanded, isTrue);
      expect(
        turnAutoCollapsed(
          turn,
          policy: const TurnFoldPolicy(),
          humanUserSeqs: const [],
        ),
        isFalse,
      );
    });

    test('轮内有插话 → 强制展开（提示词本身不算插话）', () {
      final turn = turnWith(steerSeqs: [5]);
      expect(turn.hasInterjection, isTrue);
      expect(turn.forceExpanded, isTrue);
      expect(
        turnAutoCollapsed(
          turn,
          policy: const TurnFoldPolicy(),
          humanUserSeqs: [2, 5],
        ),
        isFalse,
      );
      // 没有额外插话时，提示词不能把每个完成轮都变成强制展开。
      final promptOnly = turnWith();
      expect(promptOnly.hasInterjection, isFalse);
      expect(promptOnly.forceExpanded, isFalse);
    });

    test('aborted / interrupted / error → 强制展开，且不显示用时', () {
      for (final kind in ['aborted', 'interrupted', 'error']) {
        final turn = turnWith(endKind: kind);
        expect(turn.forceExpanded, isTrue, reason: kind);
        expect(turn.abnormalEnd, isTrue, reason: kind);
        expect(turn.durationMs, isNull, reason: kind);
        expect(turnFooterText(turn), isNot(contains('用时')), reason: kind);
        expect(
          turnAutoCollapsed(
            turn,
            policy: const TurnFoldPolicy(),
            humanUserSeqs: const [],
          ),
          isFalse,
          reason: kind,
        );
      }
    });

    test('正常完成 → 不强制展开', () {
      final turn = turnWith();
      expect(turn.forceExpanded, isFalse);
      expect(turn.abnormalEnd, isFalse);
      // 该夹具没有服务端 time → 用时不可知（不是 0）。
      expect(turn.durationMs, isNull);
    });
  });

  group('展示模式四档策略表（issue #52 note 1700 / 桌面 presentation-policy）', () {
    const cases = <WorkStepDisplayMode, (bool, StepGrouping, bool, bool)>{
      // mode: (foldCompletedTurns, stepGrouping, liveProcessDetail,
      //        settledReasoningPreview)
      WorkStepDisplayMode.concise: (true, StepGrouping.collapsed, false, false),
      WorkStepDisplayMode.standard: (true, StepGrouping.collapsed, true, true),
      WorkStepDisplayMode.detailed: (true, StepGrouping.history, true, true),
      WorkStepDisplayMode.expanded: (false, StepGrouping.none, false, true),
    };
    for (final entry in cases.entries) {
      test('${entry.key.name} 档策略', () {
        final policy = TurnFoldPolicy(mode: entry.key);
        expect(policy.foldCompletedTurns, entry.value.$1);
        expect(policy.stepGrouping, entry.value.$2);
        expect(policy.liveProcessDetail, entry.value.$3);
        expect(policy.settledReasoningPreview, entry.value.$4);
      });
    }

    test('默认「标准」+「回答结束后」', () {
      const policy = TurnFoldPolicy();
      expect(policy.mode, WorkStepDisplayMode.standard);
      expect(policy.timing, TurnFoldTiming.afterAnswer);
    });

    test('单张工具卡在所有档位都默认收起（完全展开不自动展开工具卡）', () {
      // 策略里不再有「单卡默认展开」字段：完全展开只影响整轮/过程组。
      for (final mode in WorkStepDisplayMode.values) {
        final policy = TurnFoldPolicy(mode: mode);
        expect(policy.groupsCollapsedByDefault,
            mode != WorkStepDisplayMode.expanded,
            reason: mode.name);
      }
    });
  });

  group('收起时机两档', () {
    final turn = trackerOf(oneTurn()).build().single;

    test('回答结束后：完成即自动收起（标准档）', () {
      expect(
        turnAutoCollapsed(
          turn,
          policy: const TurnFoldPolicy(timing: TurnFoldTiming.afterAnswer),
          humanUserSeqs: const [],
        ),
        isTrue,
      );
    });

    test('下次有新消息：无新 user 消息时保持展开，来了才收起', () {
      const policy = TurnFoldPolicy(timing: TurnFoldTiming.onNewMessage);
      expect(turnAutoCollapsed(turn, policy: policy, humanUserSeqs: const []), isFalse);
      expect(turnAutoCollapsed(turn, policy: policy, humanUserSeqs: const [8]), isFalse,
          reason: 'endSeq 本身不算「之后的新消息」');
      expect(turnAutoCollapsed(turn, policy: policy, humanUserSeqs: const [20]), isTrue);
      expect(newMessageArrivedAfter(turn, const [20]), isTrue);
      expect(newMessageArrivedAfter(turn, const [5]), isFalse);
    });

    test('完全展开档不看时机：完成轮保持展开', () {
      expect(
        turnAutoCollapsed(
          turn,
          policy: const TurnFoldPolicy(mode: WorkStepDisplayMode.expanded),
          humanUserSeqs: const [20],
        ),
        isFalse,
      );
    });

    test('详细档仍自动收起已完成轮（foldCompletedTurns=true）', () {
      expect(
        turnAutoCollapsed(
          turn,
          policy: const TurnFoldPolicy(mode: WorkStepDisplayMode.detailed),
          humanUserSeqs: const [20],
        ),
        isTrue,
      );
      expect(
        turnAutoCollapsed(
          turn,
          policy: const TurnFoldPolicy(mode: WorkStepDisplayMode.detailed),
          humanUserSeqs: const [],
        ),
        isTrue,
      );
    });

    test('运行中的组强制展开（底部最新组延后收起）；完成的组默认折叠', () {
      final running = trackerOf([
        ev(1, 'turn/start', {'turn': 1}),
        ev(2, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'shell'}),
        ev(3, 'tool/result', {'turn': 1, 'step': 1, 'callId': 'c1', 'text': 'ok'}),
        ev(4, 'tool/call', {'turn': 1, 'step': 2, 'callId': 'c2', 'name': 'read_file'}),
      ]).build().single;
      expect(running.groups, hasLength(2));
      for (var i = 0; i < running.groups.length; i++) {
        expect(
          groupAutoCollapsed(
            running.groups[i],
            policy: const TurnFoldPolicy(),
            turnRunning: true,
          ),
          isFalse,
          reason: '运行中的组强制展开（$i）',
        );
      }
      final done = trackerOf(oneTurn()).build().single;
      expect(
        groupAutoCollapsed(
          done.groups.first,
          policy: const TurnFoldPolicy(),
        ),
        isTrue,
        reason: '已完成的组默认折叠',
      );
    });
  });

  group('过程段（按轮内插话切段，段各折叠）', () {
    test('无插话：整轮一段，段内仍按 step 分组', () {
      final turn = trackerOf(oneTurn()).build().single;
      final segments = segmentsOf(turn);
      expect(segments, hasLength(1));
      expect(segments.single.groups.map((g) => g.step), [1, 2]);
      expect(segments.single.toolCount, 2);
    });

    test('轮内插话：过程行在插话处切成两段', () {
      final turn = trackerOf([
        ev(1, 'turn/start', {'turn': 1}),
        ev(2, 'user/message', {'text': '提示词', 'sourceKind': 'user'}),
        ev(3, 'tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'shell'}),
        ev(4, 'tool/result', {'turn': 1, 'step': 1, 'callId': 'c1', 'text': 'ok'}),
        ev(5, 'user/message', {'text': '插话', 'sourceKind': 'user'}),
        ev(6, 'tool/call', {'turn': 1, 'step': 2, 'callId': 'c2', 'name': 'read_file'}),
        ev(7, 'tool/result', {'turn': 1, 'step': 2, 'callId': 'c2', 'text': 'ok'}),
        ev(9, 'turn/end', {'turn': 1, 'reason': {'kind': 'completed'}}),
      ]).build().single;
      final segments = segmentsOf(turn);
      expect(segments, hasLength(2));
      expect(segments[0].rows.single.callId, 'c1');
      expect(segments[1].rows.single.callId, 'c2');
      expect(segments[0].startSeq, 3);
      expect(segments[1].startSeq, 6);
      expect(segments[0].summary, '1 组 · 1 次工具调用');
    });
  });

  group('用时只认服务端 time（缺省不显示）', () {
    test('起止 time 可用且正常完成 → 页脚带用时', () {
      final turn = trackerOf(oneTurn(startTime: 1000, endTime: 4500)).build().single;
      expect(turn.durationMs, 3500);
      expect(turnFooterText(turn), '已完成 · 用时 3.5 秒');
    });

    test('桌面口径：不足 1 秒按 1 秒显示（Math.max(1000, end-start)）', () {
      final turn = trackerOf(oneTurn(startTime: 1000, endTime: 1200)).build().single;
      expect(turn.durationMs, 1000);
      expect(turnFooterText(turn), '已完成 · 用时 1.0 秒');
    });

    test('旧宿主无 time → 不显示用时，也不得用本地接收时间推算', () {
      final turn = trackerOf(oneTurn(includeTime: false)).build().single;
      expect(turn.startedAtMs, isNull);
      expect(turn.endedAtMs, isNull);
      expect(turn.durationMs, isNull);
      expect(turnFooterText(turn), '已完成');
      expect(turnFooterText(turn), isNot(contains('用时')));
    });

    test('只有一端 time → 仍不显示用时', () {
      final events = oneTurn();
      final noEndTime = [
        for (final e in events)
          if (e.type == 'turn/end') ChatEvent(seq: e.seq, type: e.type, data: e.data)
          else e,
      ];
      final turn = trackerOf(noEndTime).build().single;
      expect(turn.durationMs, isNull);
      expect(turnFooterText(turn), '已完成');
    });

    test('用时格式（秒/分/小时）', () {
      expect(formatTurnDuration(400), '0.4 秒');
      expect(formatTurnDuration(12300), '12.3 秒');
      expect(formatTurnDuration(65000), '1 分 05 秒');
      expect(formatTurnDuration(3725000), '1 小时 02 分');
    });
  });

  group('单轮过程行分批展示（>50 行）', () {
    List<ProcessRow> rows(int count) => [
          for (var i = 0; i < count; i++)
            ProcessRow.tool(
              seq: i + 1,
              step: 1,
              callId: 'c$i',
              toolName: 'shell',
              status: 'success',
            ),
        ];

    test('50 行以内全量展示', () {
      final window = batchProcessRows(rows(50), processBatchSize);
      expect(window.visible, hasLength(50));
      expect(window.hidden, 0);
      expect(window.total, 50);
    });

    test('超过 50 行只展示前 50 行，并给出剩余数', () {
      final window = batchProcessRows(rows(120), processBatchSize);
      expect(window.visible, hasLength(50));
      expect(window.hidden, 70);
      expect(window.total, 120);
      expect(window.visible.first.callId, 'c0');
      expect(window.visible.last.callId, 'c49');
    });

    test('折叠摘要只给计数，不拼思维链预览（预览只作用于思考行标题）', () {
      final segment = segmentsOf(trackerOf(oneTurn()).build().single).single;
      expect(segment.summary, '思考 16 字 · 2 组 · 2 次工具调用');
      expect(segment.summary, isNot(contains('先看目录')));
    });
  });

  group('过程行预览与抬头', () {
    test('思维链折叠态首行预览截断', () {
      const row = ProcessRow.reasoning(
        seq: 1,
        step: 1,
        reasoning: '第一行预览\n第二行',
        reasoningChars: 9,
      );
      expect(row.reasoningPreview(), '第一行预览');
      final long = ProcessRow.reasoning(
        seq: 2,
        step: 1,
        reasoning: 'x' * 300,
        reasoningChars: 300,
      );
      expect(long.reasoningPreview(max: 20), '${'x' * 20}…');
    });

    test('liveProcessDetail：标准/详细档抬头附带当前工具名，简洁/完全展开只给通用文案', () {
      final group = ProcessGroup(step: 1, rows: [
        ProcessRow.tool(
          seq: 1,
          step: 1,
          callId: 'c',
          toolName: 'shell',
          status: 'running',
        ),
      ]);
      expect(processGroupHeader(group, running: true), '正在调用工具…');
      expect(
        processGroupHeader(group, running: true, showDetail: true),
        '正在调用工具…（shell）',
      );
      // 完成态不显示用时（有意简化）。
      final doneGroup = ProcessGroup(step: 1, rows: [
        ProcessRow.tool(
          seq: 1,
          step: 1,
          callId: 'c',
          toolName: 'shell',
          status: 'success',
        ),
      ]);
      expect(processGroupHeader(doneGroup, running: false), '1 次工具调用');
    });

    test('过程组抬头不显示用时（有意简化）', () {
      final group = ProcessGroup(step: 1, rows: [
        ProcessRow.tool(seq: 1, step: 1, callId: 'c', toolName: 'shell', status: 'success'),
      ]);
      expect(processGroupHeader(group, running: false), '1 次工具调用');
      expect(processGroupHeader(group, running: false), isNot(contains('用时')));
    });
  });

  group('跟踪器裁剪与重置', () {
    test('裁剪早于窗口的轮次，保留窗口内轮次', () {
      final tracker = TurnProcessTracker();
      for (final event in oneTurn(turn: 1)) {
        tracker.observe(event);
      }
      for (final event in [
        ev(11, 'turn/start', {'turn': 2}),
        ev(12, 'tool/call', {'turn': 2, 'step': 1, 'callId': 'c2', 'name': 'shell'}),
        ev(13, 'turn/end', {'turn': 2, 'reason': {'kind': 'completed'}}),
      ]) {
        tracker.observe(event);
      }
      expect(tracker.build(), hasLength(2));
      tracker.pruneBefore(11);
      final kept = tracker.build();
      expect(kept.map((t) => t.turn), [2]);
    });

    test('reset 后重新折叠为空', () {
      final tracker = trackerOf(oneTurn());
      expect(tracker.build(), isNotEmpty);
      tracker.reset();
      expect(tracker.build(), isEmpty);
    });
  });
}
