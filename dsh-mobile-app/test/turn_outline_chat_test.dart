// issue #25 二期：宿主轮次大纲接进对话页的集成测试（Seam 3）。
//
// `turn_outline_logic_test.dart` 覆盖纯逻辑（合并/翻页终止/说明文字）；本文件把真实
// `ChatScreen` 接上假后端，验证"未加载刻度长什么样、点它会怎样、不可达时说什么、
// 能力位为假时退不退回一期"这些**用户可观察**行为。不锁死内部实现。

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/turn_navigator_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 造 `from..turns` 轮事件：每轮 = turn/start + 用户消息 + 助手长回复（够长才能上翻）。
/// 第 n 轮的起始序号 = `1 + (n-1)*3`。
List<Map<String, dynamic>> _turnsEvents({required int turns, int from = 1}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1 + (from - 1) * 3;
  for (var turn = from; turn <= turns; turn++) {
    events.add({
      'seq': seq++,
      'type': 'turn/start',
      'data': {'turn': turn},
    });
    events.add({
      'seq': seq++,
      'type': 'user/message',
      'data': {
        'messageId': 'user-$turn',
        'text': '第 $turn 轮的问题',
        'sourceKind': 'user',
      },
    });
    events.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {
        'turn': turn,
        'messageId': 'assistant-$turn',
        'text': '第 $turn 轮的回答' * 40,
      },
    });
  }
  return events;
}

int _seqOfTurn(int turn) => 1 + (turn - 1) * 3;

/// 假后端：会话共 [sessionTurns] 轮，客户端只加载**最近** [loadedTurns] 轮
/// （真实场景就是如此：初始只拉最近一页），更早的轮次靠大纲补进刻度轨。
class _OutlineBackend {
  _OutlineBackend({
    this.sessionTurns = 10,
    this.loadedTurns = 2,
    this.outlineState = 'available',
    this.supported = true,
    this.exhaustedOlder = false,
  }) {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://outline.test'
      ..path = '/m'
      ..token = ''
      ..timelineCapabilities = const TimelineCapabilities(
        version: 1,
        live: true,
        history: true,
        detail: true,
        unknownEvents: true,
        callCorrelation: true,
      )
      ..turnOutlineCapabilities = TurnOutlineCapabilities(
        version: 1,
        supported: supported,
        unloaded: supported,
        truncated: supported,
      );
  }

  final int sessionTurns;
  final int loadedTurns;
  final String outlineState;
  final bool supported;

  /// 更早历史已到顶端（上翻返回空页）。
  final bool exhaustedOlder;

  late final Api api;

  /// 记录带 `before` 的上翻请求（页大小用于断言"跨页跳转一次翻足够多"）。
  final List<Map<String, String>> olderRequests = [];
  int outlineRequests = 0;

  /// 置上时，带 `before` 的上翻请求会挂起，直到测试 complete 它。
  Completer<void>? holdOlder;

  /// 置上时，每个 `/turn-outline` 请求都挂起，直到 `releaseOutline(nth)` 放行
  /// （用于制造"更早的请求后完成"的逆序场景）。
  bool holdOutlineCalls = false;
  final Map<int, Completer<void>> _outlineGates = {};
  final Map<int, String> outlineStateByCall = {};

  void releaseOutline(int index) {
    _outlineGates.remove(index)?.complete();
  }

  int get _firstLoadedTurn => (sessionTurns - loadedTurns + 1).clamp(1, sessionTurns);

  /// 更早的一页：**服务端最多返回 `limit` 条事件**（每轮 3 条），所以一次上翻覆盖
  /// 的轮数与 limit 成正比——这正是 issue #25 要"一次翻足够多"的原因。
  Map<String, dynamic> _olderPage(int beforeSeq, int limit) {
    final cursorTurn = ((beforeSeq + 2) ~/ 3); // before 之前的那一轮
    final last = cursorTurn - 1;
    if (exhaustedOlder || last < 1) {
      return {'ok': true, 'events': <Object>[], 'hasMore': false};
    }
    final maxTurns = (limit ~/ 3).clamp(1, sessionTurns);
    final first = (last - maxTurns + 1).clamp(1, sessionTurns);
    return {
      'ok': true,
      'events': _turnsEvents(turns: last, from: first),
      'hasMore': first > 1,
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/turn-outline') {
      final nth = outlineRequests;
      outlineRequests += 1;
      if (holdOutlineCalls) {
        final gate = Completer<void>();
        _outlineGates[nth] = gate;
        await gate.future;
      }
      body = switch (outlineStateByCall[nth] ?? outlineState) {
        'empty' => {'ok': true, 'state': 'empty', 'turns': <Object>[]},
        'read-failed' => {
            'ok': true,
            'state': 'read-failed',
            'code': 'turn-outline-timeout',
            'degraded': true,
            'turns': <Object>[],
          },
        _ => {
            'ok': true,
            'state': 'available',
            'asOfSeq': _seqOfTurn(sessionTurns),
            'turns': [
              for (var turn = 1; turn <= sessionTurns; turn++)
                {
                  'turn': turn,
                  'seq': _seqOfTurn(turn),
                  'prompt': '大纲第 $turn 轮提示',
                  'response': '大纲第 $turn 轮回复',
                },
            ],
          },
      };
    } else if (path == '/m/api/history') {
      final params = request.url.queryParameters;
      if (params.containsKey('before')) {
        olderRequests.add(params);
        // 需要"挂起旧请求"的用例：先卡住这一页，等测试放行再返回。
        final hold = holdOlder;
        if (hold != null) await hold.future;
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final limit = int.tryParse(params['limit'] ?? '') ?? 30;
        body = _olderPage(before, limit);
      } else {
        body = {
          'ok': true,
          'events': _turnsEvents(turns: sessionTurns, from: _firstLoadedTurn),
          'hasMore': false,
        };
      }
    } else if (path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else {
      body = {'ok': true};
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required _OutlineBackend backend,
  required AppStore store,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      key: const ValueKey('outline-chat'),
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _scrollUp(WidgetTester tester, {double by = 600}) async {
  await tester.drag(find.byType(CustomScrollView), Offset(0, by));
  await tester.pumpAndSettle();
}

/// `hello` 帧会起 debounce / collect 定时器；用例结束前先卸载页面再释放 store，
/// 否则 flutter_test 会以 "A Timer is still pending after the widget tree was disposed" 失败。
Future<void> _teardownStore(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox());
  store.dispose();
}

/// 有界推进若干帧：跳转进行中时该齿在脉冲（无限动画），`pumpAndSettle` 不会收敛。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 16}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 轨道内第 [index] 个刻度（0 基）的中心在轨道本地坐标里的 y。
double _tickLocalY(int index) => 6 + index * 10 + 5;

void main() {
  testWidgets('宿主大纲带来未加载刻度：刻度数覆盖整个会话而不只是已加载窗口', (tester) async {
    final backend = _OutlineBackend(sessionTurns: 10, loadedTurns: 2);
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    expect(backend.outlineRequests, greaterThan(0), reason: '会话打开后应拉一次大纲');
    expect(find.byType(TurnNavigatorRail), findsOneWidget);
    for (var turn = 1; turn <= 10; turn++) {
      expect(find.byKey(ValueKey<String>('turn-tick-$turn')), findsOneWidget,
          reason: '第 $turn 轮应有刻度（9/10 已加载，1..8 来自宿主大纲）');
    }
    expect(find.byKey(const ValueKey<String>('turn-tick-11')), findsNothing);
  });

  testWidgets('未加载刻度的预览来自大纲：不必先跳过去就知道那是哪一轮', (tester) async {
    // 会话 20 轮、只加载最近 2 轮（19/20）；上翻一页（30 条 ≈ 10 轮）后仍有 1..8 未加载。
    final backend = _OutlineBackend(sessionTurns: 20, loadedTurns: 2);
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    // 长按第 6 轮那个刻度（0 基 index 5）：它的提示词本地没有，应由大纲补齐。
    final railRect = tester.getRect(find.byType(TurnNavigatorRail));
    final gesture = await tester.startGesture(
      Offset(railRect.center.dx, railRect.top + _tickLocalY(5)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.textContaining('大纲第 6 轮提示'), findsOneWidget,
        reason: '未加载轮次的预览应由大纲补齐');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点未加载刻度：按 200 条/页跨页加载，覆盖后定位到该轮', (tester) async {
    final backend = _OutlineBackend(sessionTurns: 20, loadedTurns: 2);
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('turn-tick-6')),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      backend.olderRequests.any((r) => r['limit'] == '200'),
      isTrue,
      reason: '未加载刻度必须用跨页跳转的 200 条/页（不改动既有 30 条/页），'
          '实际请求：${backend.olderRequests}',
    );
    expect(find.text('第 6 轮的问题'), findsOneWidget,
        reason: '翻页完成后应落在目标轮');
    expect(tester.takeException(), isNull);
  });

  testWidgets('到达顶端仍不覆盖：明确说明不可达，不静默', (tester) async {
    final backend = _OutlineBackend(
      sessionTurns: 20,
      loadedTurns: 2,
      exhaustedOlder: true,
    );
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('turn-tick-1')),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('不可达'), findsOneWidget,
        reason: '目标不可达必须明确告知（ADR 0018 有意偏离电脑端的静默停下）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲读取失败：退回一期行为并说明原因', (tester) async {
    final backend = _OutlineBackend(
      sessionTurns: 6,
      loadedTurns: 6,
      outlineState: 'read-failed',
    );
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    // 仍按一期渲染已加载轮次（不是空白、也不是报错）。
    expect(find.byType(TurnNavigatorRail), findsOneWidget);
    for (var turn = 1; turn <= 6; turn++) {
      expect(find.byKey(ValueKey<String>('turn-tick-$turn')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey<String>('turn-tick-7')), findsNothing);
    expect(find.textContaining('超时'), findsOneWidget, reason: '读取失败要有明确说明');
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力位为假：不发大纲请求，退回一期行为', (tester) async {
    final backend = _OutlineBackend(
      sessionTurns: 6,
      loadedTurns: 6,
      supported: false,
    );
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    expect(backend.outlineRequests, 0, reason: '声明不支持就不该发请求');
    expect(find.byType(TurnNavigatorRail), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('turn-tick-6')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('turn-tick-7')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ── issue #25 评审 note 1066 的回归 ──────────────────────────────────

  testWidgets('能力后到：能力声明到达后补拉大纲，不再只有本地刻度', (tester) async {
    final backend = _OutlineBackend(
      sessionTurns: 20,
      loadedTurns: 2,
      supported: false,
    );
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);
    expect(backend.outlineRequests, 0, reason: '声明不支持时不该发请求');

    // 首连时序：历史先完成，能力声明后到（supported=false → true）。
    backend.api.turnOutlineCapabilities = const TurnOutlineCapabilities(
      version: 1,
      supported: true,
      unloaded: true,
      truncated: true,
    );
    store.injectFrame({
      'type': 'hello',
      'capabilities': {
        'turnOutline': {
          'version': 1,
          'supported': true,
          'unloaded': true,
          'truncated': true,
        },
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(backend.outlineRequests, greaterThan(0),
        reason: '能力后到时必须补拉一次大纲（评测 P2 反例：0 次请求）');
    expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsOneWidget,
        reason: '补拉后未加载刻度应出现');
    expect(tester.takeException(), isNull);
    await _teardownStore(tester, store);
  });

  testWidgets('能力被撤销：旧大纲刻度立即失效，不再显示陈旧阶梯', (tester) async {
    final backend = _OutlineBackend(sessionTurns: 20, loadedTurns: 2);
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);
    expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsOneWidget);

    backend.api.turnOutlineCapabilities = const TurnOutlineCapabilities(
      version: 1,
      supported: false,
    );
    store.injectFrame({
      'type': 'hello',
      'capabilities': {
        'turnOutline': {'version': 1, 'supported': false},
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsNothing,
        reason: '能力撤销后不得继续渲染上一台机器的大纲刻度');
    expect(tester.takeException(), isNull);
    await _teardownStore(tester, store);
  });

  testWidgets('连续选择：旧跨页跳转完成后不得再改落点', (tester) async {
    final backend = _OutlineBackend(sessionTurns: 20, loadedTurns: 2);
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    final listScrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    double offset() =>
        tester.state<ScrollableState>(listScrollable).position.pixels;

    // 1) 选未加载的第 6 轮，把它的跨页请求挂起（该齿开始脉冲）。
    backend.holdOlder = Completer<void>();
    await tester.tap(
      find.byKey(const ValueKey<String>('turn-tick-6')),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 2) 期间改选已加载的第 19 轮。旧跳转仍在脉冲 → `pumpAndSettle` 永远不会收敛，
    //    所以这里用有界 pump 推进。
    await tester.tap(
      find.byKey(const ValueKey<String>('turn-tick-19')),
      warnIfMissed: false,
    );
    await _pumpFrames(tester);
    final afterSecondChoice = offset();
    expect(find.text('第 19 轮的问题'), findsOneWidget,
        reason: '第二次选择应先落在第 19 轮');

    // 3) 放行旧请求：它已完成（或已作废），但**不得**再把视口拉回第 6 轮。
    backend.holdOlder!.complete();
    await _pumpFrames(tester);
    expect(find.text('第 19 轮的问题'), findsOneWidget,
        reason: '旧跳转完成后不得覆盖新选择的落点（评测 P2 反例：视口被拉回第 6 轮附近）');
    expect((offset() - afterSecondChoice).abs(), lessThan(3000),
        reason: '旧跳转不得把视口整体搬走（未被取消时会冲向第 6 轮，位移数千像素）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('该会话无大纲：给出与"能力缺失"不同的明确说明', (tester) async {
    final backend = _OutlineBackend(
      sessionTurns: 6,
      loadedTurns: 6,
      outlineState: 'empty',
    );
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('这个会话'), findsOneWidget,
        reason: 'empty 必须有说明（评测 P2 反例：说明被 UI 排除）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('能力缺失：给出与"该会话无大纲"不同的明确说明', (tester) async {
    final backend = _OutlineBackend(
      sessionTurns: 6,
      loadedTurns: 6,
      supported: false,
    );
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('这台电脑'), findsOneWidget,
        reason: 'capability-missing 必须有说明（评测 P2 反例：说明被 UI 排除）');
    expect(tester.takeException(), isNull);
  });

  // ── 第二轮评审 note 1073 的回归 ──────────────────────────────────────

  Finder pulsingTicks() => find.descendant(
        of: find.byType(TurnNavigatorRail),
        matching: find.byType(FadeTransition),
      );

  testWidgets('用户主动滚动取消跳转后，旧刻度不再一直脉冲', (tester) async {
    final backend = _OutlineBackend(sessionTurns: 20, loadedTurns: 2);
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    backend.holdOlder = Completer<void>();
    await tester.tap(
      find.byKey(const ValueKey<String>('turn-tick-6')),
      warnIfMissed: false,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(pulsingTicks(), findsWidgets, reason: '跳转进行中该齿应在脉冲');

    // 用户主动拖动消息流 = 取消本次跳转。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    backend.holdOlder!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));

    expect(pulsingTicks(), findsNothing,
        reason: '取消入口必须主动结束旧操作的脉冲（旧 finally 因世代失效不会再收尾）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('大纲刷新：迟到的旧失败不得覆盖更新的成功', (tester) async {
    final backend = _OutlineBackend(sessionTurns: 20, loadedTurns: 2);
    backend.holdOutlineCalls = true;
    backend.outlineStateByCall[0] = 'read-failed';
    backend.outlineStateByCall[1] = 'available';
    final store = AppStore()..sessionId = 'session-outline';
    await _pumpChat(tester, backend: backend, store: store);
    await _scrollUp(tester);

    // 第二次刷新（能力事件）→ 请求 #1
    store.injectFrame({
      'type': 'hello',
      'capabilities': {
        'turnOutline': {'version': 1, 'supported': true, 'unloaded': true, 'truncated': true},
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.outlineRequests, greaterThanOrEqualTo(2),
        reason: '应有两个重叠的大纲刷新请求');

    backend.releaseOutline(1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsOneWidget,
        reason: '较新的刷新给出完整阶梯（20 轮）');

    // 更早的 #0 现在才返回失败：不得抹掉较新的成功。
    backend.releaseOutline(0);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsOneWidget,
        reason: '迟到的旧失败不得覆盖新成功（评测 P2 反例：退回 2 个本地刻度）');
    expect(backend.outlineRequests, greaterThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
    await _teardownStore(tester, store);
  });
}
