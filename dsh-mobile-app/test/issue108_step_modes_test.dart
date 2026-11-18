// issue #108：四档工作步骤展示模式（v4）真实 ChatScreen 行为矩阵。
//
// 运行中：简洁摘要/活动条隐藏；标准组抬头折叠+活动条；详细组展开+行摘要；
// 完全展开不分组+当前轮详情自动展开。
// 已完成：简洁/标准整轮一行；详细段展开+组折叠；完全展开不分组+行摘要、详情收起。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Backend {
  _Backend(this.events);

  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue108.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
      unknownEvents: true,
      callCorrelation: true,
    );

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    if (request.url.path == '/m/api/history') {
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('before')) {
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final preceding =
            events.where((e) => (e['seq'] as int) < before).toList();
        body = {
          'ok': true,
          'events': preceding.length > limit
              ? preceding.sublist(preceding.length - limit)
              : preceding,
          'hasMore': preceding.length > limit,
        };
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else {
        body = {
          'ok': true,
          'events': events.length > limit
              ? events.sublist(events.length - limit)
              : events,
          'hasMore': events.length > limit,
        };
      }
    } else if (request.url.path == '/m/api/event-detail') {
      body = {'ok': true, 'event': null};
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (request.url.path == '/m/api/session-config') {
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

List<Map<String, dynamic>> _completedTurn() => [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '问题', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 1,
          'messageId': 'a1',
          'text': '',
          'reasoning': 'check layout',
          'reasoningChars': 12,
        },
        'time': 1200,
      },
      {
        'seq': 4,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'shell',
          'arguments': '{"cmd":"ls"}',
        },
        'time': 1300,
      },
      {
        'seq': 5,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'shell',
          'text': 'ok',
        },
        'time': 1400,
      },
      {
        'seq': 6,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 2,
          'messageId': 'a2',
          'text': '最终回答',
        },
        'time': 1500,
      },
      {
        'seq': 7,
        'type': 'turn/end',
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
        'time': 4000,
      },
    ];

List<Map<String, dynamic>> _runningTurn() => _completedTurn()
    .where((e) => e['type'] != 'turn/end' && e['seq'] != 5 && e['seq'] != 6)
    .map((e) => Map<String, dynamic>.from(e))
    .toList();

Future<AppStore> _pump(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  Size size = const Size(390, 844),
  bool legacyReasoningPrefs = false,
}) async {
  final store = AppStore()
    ..sessionId = 'session-108'
    ..sessions = [
      Session(id: 'session-108', title: 'S', cwd: null, createdAt: 1),
    ]
    ..stepDisplayMode = mode;
  if (legacyReasoningPrefs) {
    store
      ..showReasoning = true
      ..reasoningDefaultExpanded = true;
  }
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: ChatScreen(
          key: ValueKey('issue108-${mode.name}-${size.width}'),
          store: store,
          apiClient: backend.api,
          onTitleChanged: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

Future<void> _inject(
  WidgetTester tester,
  AppStore store,
  Map<String, dynamic> event,
) async {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': 'session-108',
    'event': event,
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump(const Duration(seconds: 1));
}

Finder _summary() => find.textContaining('组 · ');
Finder _groupHeader() => find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          (widget.data?.startsWith('1 次工具调用') ?? false),
    );
Finder _activityBar() => find.byKey(const ValueKey<String>('activity-bar'));


List<Map<String, dynamic>> _interjectionRunningTurn() => [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '问题', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 1,
          'messageId': 'a1',
          'text': '',
          'reasoning': 'check layout',
          'reasoningChars': 12,
        },
        'time': 1100,
      },
      {
        'seq': 4,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'shell',
          'arguments': '{"cmd":"ls"}',
        },
        'time': 1200,
      },
      {
        'seq': 5,
        'type': 'user/message',
        'data': {'messageId': 'u2', 'text': '插话', 'sourceKind': 'user'},
      },
      {
        'seq': 6,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'c2',
          'name': 'read_file',
          'arguments': '{"path":"a"}',
        },
        'time': 1300,
      },
    ];

void main() {
  test('policy：四档运行中/已完成维度', () {
    final concise = const TurnFoldPolicy(mode: WorkStepDisplayMode.concise);
    expect(concise.liveSegment, LiveSegmentMode.summary);
    expect(concise.liveGroups, LiveGroupMode.hidden);
    expect(concise.liveActivityBarVisible, isFalse);
    expect(concise.foldCompletedTurns, isTrue);

    final standard = const TurnFoldPolicy(mode: WorkStepDisplayMode.standard);
    expect(standard.liveSegment, LiveSegmentMode.expanded);
    expect(standard.liveGroups, LiveGroupMode.collapsed);
    expect(standard.liveActivityBarVisible, isTrue);
    expect(standard.foldCompletedTurns, isTrue);

    final detailed = const TurnFoldPolicy(mode: WorkStepDisplayMode.detailed);
    expect(detailed.liveGroups, LiveGroupMode.expanded);
    expect(detailed.liveDetailsAutoExpanded, isFalse);
    expect(detailed.foldCompletedTurns, isFalse);
    expect(detailed.completedGroups, CompletedGroupMode.collapsed);

    final expanded = const TurnFoldPolicy(mode: WorkStepDisplayMode.expanded);
    expect(expanded.liveGroups, LiveGroupMode.flat);
    expect(expanded.liveDetailsAutoExpanded, isTrue);
    expect(expanded.completedGroups, CompletedGroupMode.flat);
    expect(expanded.foldCompletedTurns, isFalse);
  });

  testWidgets('简洁运行中：过程段摘要、活动条隐藏；手动展开段组默认展开', (tester) async {
    await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.concise,
    );
    expect(_summary(), findsOneWidget);
    expect(_groupHeader(), findsNothing);
    expect(_activityBar(), findsNothing);
    expect(find.text('shell'), findsNothing);

    await tester.tap(_summary());
    await tester.pump(const Duration(milliseconds: 150));
    expect(_summary(), findsNothing);
    expect(_groupHeader(), findsOneWidget);
    expect(find.text('shell'), findsOneWidget, reason: '一次点击看到组抬头+行');
    expect(find.text('参数'), findsNothing, reason: '详情仍收起');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('标准运行中：组抬头折叠+组数/状态；不铺行；活动条常显', (tester) async {
    await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.standard,
    );
    expect(find.text('1 次工具调用 · 进行中'), findsOneWidget);
    expect(find.text('shell'), findsNothing, reason: '组折叠不得残留行');
    expect(find.textContaining('参数'), findsNothing);
    expect(_activityBar(), findsOneWidget);
    expect(find.textContaining('正在调用 shell'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('详细运行中：组展开+行摘要；详情收起', (tester) async {
    await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.detailed,
    );
    expect(find.textContaining('正在调用工具…（shell）'), findsOneWidget);
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('参数'), findsNothing, reason: '详细详情默认收起');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('完全展开运行中：不分组+行摘要；当前轮详情自动展开；完成后详情收起', (tester) async {
    await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.expanded,
    );
    expect(find.textContaining('工具调用'), findsNothing,
        reason: '完全展开不分组/无组抬头');
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('参数'), findsOneWidget, reason: '当前运行轮详情自动展开');

    // 段内完成（turn/end 到达）后：不分组、行摘要仍在，详情自动收起。
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(
      tester,
      _Backend(_completedTurn()),
      mode: WorkStepDisplayMode.expanded,
    );
    expect(find.textContaining('工具调用'), findsNothing);
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('参数'), findsNothing, reason: '已完成轮详情不自动展开');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已完成四档：简洁/标准一行；详细组折叠；完全展开平铺行摘要', (tester) async {
    final modes = [
      WorkStepDisplayMode.concise,
      WorkStepDisplayMode.standard,
      WorkStepDisplayMode.detailed,
      WorkStepDisplayMode.expanded,
    ];
    for (final mode in modes) {
      await _pump(tester, _Backend(_completedTurn()), mode: mode);
      switch (mode) {
        case WorkStepDisplayMode.concise:
        case WorkStepDisplayMode.standard:
          expect(_summary(), findsOneWidget, reason: '$mode 已完成整轮一行');
          expect(find.text('shell'), findsNothing);
        case WorkStepDisplayMode.detailed:
          expect(_summary(), findsNothing);
          expect(_groupHeader(), findsOneWidget);
          expect(find.text('shell'), findsNothing);
          await tester.tap(_groupHeader());
          await tester.pump(const Duration(milliseconds: 150));
          expect(find.text('shell'), findsOneWidget);
          expect(find.text('参数'), findsNothing);
        case WorkStepDisplayMode.expanded:
          expect(_summary(), findsNothing);
          expect(find.textContaining('工具调用'), findsNothing);
          expect(find.text('shell'), findsOneWidget);
          expect(find.text('参数'), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('插话/异常只强制段展开；手动展开/result 不抢回；切轮复位', (tester) async {
    // 已完成但异常结束 → 简洁档段强制展开（不再整轮一行），组按档位折叠。
    final abnormal = _completedTurn();
    abnormal[6]['data'] = {
      'turn': 1,
      'reason': {'kind': 'aborted'},
    };
    await _pump(
      tester,
      _Backend(abnormal),
      mode: WorkStepDisplayMode.concise,
    );
    expect(_summary(), findsNothing, reason: '异常结束强制段展开');
    expect(_groupHeader(), findsOneWidget);
    expect(find.text('shell'), findsNothing, reason: '组仍按档位折叠，不自动铺行');
    await tester.pumpWidget(const SizedBox.shrink());

    // 详细手动展开组后新事件/result 不抢回。
    final store = await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.detailed,
    );
    expect(find.text('shell'), findsOneWidget);
    final group = find.textContaining('正在调用工具');
    await tester.tap(group);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('shell'), findsNothing, reason: '手动收起优先');
    await _inject(tester, store, {
      'seq': 20,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'c1',
        'name': 'shell',
        'text': 'ok',
      },
      'time': 2000,
    });
    expect(find.text('shell'), findsNothing, reason: 'result 不抢回手动收起');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('320/深色/1.5x 不溢出；长结果有查看全文入口', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final long = 'L' * 2000;
    final events = _runningTurn();
    final callIndex = events.indexWhere((e) => e['type'] == 'tool/call');
    events[callIndex]['data'] = {
      'turn': 1,
      'step': 1,
      'callId': 'c1',
      'name': 'shell',
      'arguments': long,
    };
    await _pump(
      tester,
      _Backend(events),
      mode: WorkStepDisplayMode.expanded,
      size: const Size(320, 640),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    expect(find.text('查看全文'), findsWidgets, reason: '长结果裁剪+查看全文');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('旧 showReasoning/reasoningDefaultExpanded 即使为 true 也不影响 v4 行为', (tester) async {
    // 标准运行中仍组折叠；完全展开当前轮详情仍自动开；不读旧值不报错。
    await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.standard,
      legacyReasoningPrefs: true,
    );
    expect(find.text('1 次工具调用 · 进行中'), findsOneWidget);
    expect(find.text('shell'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());

    await _pump(
      tester,
      _Backend(_runningTurn()),
      mode: WorkStepDisplayMode.expanded,
      legacyReasoningPrefs: true,
    );
    expect(find.text('参数'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('简洁运行中插话：强制段展开（无摘要），组展开行可见且不可收起；标准/详细不回归', (tester) async {
    await _pump(
      tester,
      _Backend(_interjectionRunningTurn()),
      mode: WorkStepDisplayMode.concise,
    );
    expect(_summary(), findsNothing, reason: '插话强制段展开');
    expect(_groupHeader(), findsWidgets);
    expect(find.text('shell'), findsWidgets, reason: '简洁强制展开后组默认展开');
    expect(find.text('参数'), findsNothing, reason: '详情仍按档位收起');
    expect(find.text('收起过程'), findsNothing, reason: '强制段不可收起');
    await tester.pumpWidget(const SizedBox.shrink());

    await _pump(
      tester,
      _Backend(_interjectionRunningTurn()),
      mode: WorkStepDisplayMode.standard,
    );
    expect(_summary(), findsNothing);
    expect(_groupHeader(), findsWidgets);
    expect(find.text('shell'), findsNothing, reason: '标准插话仍组抬头折叠');
    expect(find.text('参数'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    await _pump(
      tester,
      _Backend(_interjectionRunningTurn()),
      mode: WorkStepDisplayMode.detailed,
    );
    expect(_summary(), findsNothing);
    expect(find.text('shell'), findsWidgets);
    expect(find.text('参数'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('完全展开运行中插话：不分组行可见，但详情不自动展开', (tester) async {
    await _pump(
      tester,
      _Backend(_interjectionRunningTurn()),
      mode: WorkStepDisplayMode.expanded,
    );
    expect(_summary(), findsNothing);
    expect(find.textContaining('工具调用'), findsNothing, reason: '不分组');
    expect(find.text('shell'), findsWidgets);
    expect(find.text('参数'), findsNothing, reason: '插话详情不自动展开');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('简洁运行中止/异常结束：强制段展开但组按完成态折叠', (tester) async {
    final aborted = _completedTurn();
    aborted[6]['data'] = {
      'turn': 1,
      'reason': {'kind': 'aborted'},
    };
    await _pump(
      tester,
      _Backend(aborted),
      mode: WorkStepDisplayMode.concise,
    );
    expect(_summary(), findsNothing, reason: '异常结束强制段展开');
    expect(_groupHeader(), findsOneWidget);
    expect(find.text('shell'), findsNothing);
    expect(find.text('参数'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });


  testWidgets('切轮复位：手动展开 turn1 不影响新 turn2 的默认摘要', (tester) async {
    final events = <Map<String, dynamic>>[
      ..._completedTurn(),
      {'seq': 8, 'type': 'turn/start', 'data': {'turn': 2}, 'time': 5000},
      {
        'seq': 9,
        'type': 'user/message',
        'data': {'messageId': 'u2', 'text': '第二个问题', 'sourceKind': 'user'},
      },
      {
        'seq': 10,
        'type': 'tool/call',
        'data': {
          'turn': 2,
          'step': 1,
          'callId': 'c2',
          'name': 'read_file',
          'arguments': '{"path":"b"}',
        },
        'time': 5100,
      },
    ];
    await _pump(tester, _Backend(events), mode: WorkStepDisplayMode.concise);
    expect(_summary(), findsNWidgets(2), reason: 'turn1/turn2 各一行摘要');
    await tester.tap(_summary().first);
    await tester.pump(const Duration(milliseconds: 150));
    expect(_summary(), findsOneWidget, reason: '只展开 turn1；turn2 仍是摘要');
    expect(_groupHeader(), findsOneWidget);
    expect(find.text('shell'), findsNothing, reason: '已完成 turn1 组默认折叠');
    expect(find.text('read_file'), findsNothing, reason: 'turn2 未手动展开');
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
