// issue #84（#51 回归）：活动条只对「真正可见」的运行中工具去重。
//
// 根因：活动条用的是 renderedCallIds（过程块承载集合）——它包含被组折叠、50 行分批
// 隐藏、以及离屏不确定的行，导致运行中工具在界面上看不见、活动条也被吞掉。
// 修复：新增 `_ProcessPlan.visibleToolCallIds`（segment 展开 + 组展开 + visibleRowSeqs），
// 活动条只对其中 callId 去重；折叠/分批隐藏/离屏/无锚点仍保留活动条。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-84';
const _activityBarToolsKey = ValueKey<String>('activity-bar-tools');

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue84.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: false,
      unknownEvents: true,
      callCorrelation: true,
    );

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    final path = request.url.path;
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
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

/// 运行中的一轮：turn/start + user + [completed] 个已完成工具 + 1 个运行中工具。

/// 少于 50 行：目标 long-shell 运行中、其余为已结束工具；总数 15 行即可把
/// 目标行推出视口（不借 50 行分批制造“离屏”假证据）。
List<Map<String, dynamic>> _runningToolAboveEvents({int ended = 7}) {
  return <Map<String, dynamic>>[
    {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
    {
      'seq': 2,
      'type': 'user/message',
      'data': {'messageId': 'u1', 'text': '长任务', 'sourceKind': 'user'},
    },
    {
      'seq': 3,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'long-shell',
        'name': 'shell',
        'arguments': 'sleep 60',
      },
    },
    for (var i = 0; i < ended; i++) ...[
      {
        'seq': 4 + i * 2,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': i + 2,
          'callId': 'done-$i',
          'name': 'bash',
          'arguments': 'echo $i',
        },
      },
      {
        'seq': 5 + i * 2,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': i + 2,
          'callId': 'done-$i',
          'name': 'bash',
          'text': 'ok $i',
        },
      },
    ],
  ];
}

List<Map<String, dynamic>> _runningEvents({
  int completedTools = 0,
  String runningTool = 'shell',
  bool withTurnStart = true,
  String? longAssistant,
  int startSeq = 1,
}) {
  final events = <Map<String, dynamic>>[];
  var seq = startSeq;
  if (withTurnStart) {
    events.add({'seq': seq++, 'type': 'turn/start', 'data': {'turn': 1}});
  }
  events.add({
    'seq': seq++,
    'type': 'user/message',
    'data': {'messageId': 'u1', 'text': '问题', 'sourceKind': 'user'},
  });
  if (longAssistant != null) {
    events.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {'turn': 1, 'step': 1, 'messageId': 'a-long', 'text': longAssistant},
    });
  }
  for (var i = 0; i < completedTools; i++) {
    events.add({
      'seq': seq++,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': i + 1,
        'callId': 'done-$i',
        'name': 'bash',
        'arguments': 'echo $i',
      },
    });
    events.add({
      'seq': seq++,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': i + 1,
        'callId': 'done-$i',
        'name': 'bash',
        'text': 'ok $i',
      },
    });
  }
  events.add({
    'seq': seq++,
    'type': 'tool/call',
    'data': {
      'turn': 1,
      'step': completedTools + 1,
      'callId': 'running-tool',
      'name': runningTool,
      'arguments': 'sleep 1',
    },
  });
  return events;
}

Future<AppStore> _pumpChat(WidgetTester tester, _Backend backend) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [
      Session(id: _session, title: 'S', cwd: null, createdAt: 1),
    ];
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      key: const ValueKey('issue84-chat'),
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  // 多泵两帧：首帧 layout 后过程工具行的 GlobalKey 才挂载，活动条需一次几何重建。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
  return store;
}

void main() {
  testWidgets('运行工具在过程块中真实可见：活动条不重复（组抬头/工具行仍在）', (tester) async {
    await _pumpChat(tester, _Backend(events: _runningEvents()));
    expect(find.textContaining('正在调用工具'), findsOneWidget);
    expect(find.text('shell'), findsWidgets);
    expect(
      find.byKey(_activityBarToolsKey),
      findsNothing,
      reason: '工具行可见时活动条不应重复同一运行工具',
    );
    expect(find.textContaining('正在调用 shell…'), findsNothing);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('运行工具在第 51 行被 50 行分批隐藏：活动条保留', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: _runningEvents(completedTools: 50)),
    );
    // 底部（钉住）时运行工具在第 51 行被分批隐藏：工具行不可见 → 活动条必须保留。
    expect(
      find.byKey(_activityBarToolsKey),
      findsOneWidget,
      reason: '工具行被分批隐藏时活动条必须保留，避免运行状态完全不可见',
    );
    expect(find.textContaining('正在调用 shell…'), findsOneWidget);
    // 懒构建 extent 会随构建修正：分帧把视口收敛到真实底部，确认「显示更多」入口。
    final pos = tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ))
        .position;
    for (var i = 0; i < 12; i++) {
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pump(const Duration(milliseconds: 120));
      if (find.textContaining('显示更多').evaluate().isNotEmpty) break;
    }
    expect(
      find.textContaining('显示更多'),
      findsOneWidget,
      reason: '51 行应触发 50 行分批（显示更多入口）',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('手动收起运行中的组：工具行隐藏，活动条恢复', (tester) async {
    await _pumpChat(tester, _Backend(events: _runningEvents()));
    expect(find.byKey(_activityBarToolsKey), findsNothing);
    // 运行中的组默认展开；点组抬头手动收起。
    await tester.tap(find.textContaining('正在调用工具'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(_activityBarToolsKey),
      findsOneWidget,
      reason: '组收起后运行工具不可见 → 活动条恢复',
    );
    expect(find.textContaining('正在调用 shell…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('无过程块锚点/旧数据：活动条仍显示运行工具', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: _runningEvents(withTurnStart: false)),
    );
    expect(
      find.byKey(_activityBarToolsKey),
      findsOneWidget,
      reason: '无 turn/start 锚点时过程块不承载工具 → 活动条保留',
    );
    expect(find.textContaining('正在调用 shell…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('上翻离开底部（钉住失效）：活动条恢复显示运行工具', (tester) async {
    await _pumpChat(
      tester,
      _Backend(
        events: [
          // 若干短历史消息制造可滚动高度；当前轮在底部且运行工具真实可见。
          for (var i = 0; i < 10; i++) ...[
            {
              'seq': 1 + i * 2,
              'type': 'user/message',
              'data': {'messageId': 'old-u$i', 'text': '旧问题 $i', 'sourceKind': 'user'},
            },
            {
              'seq': 2 + i * 2,
              'type': 'assistant/message',
              'data': {
                'turn': 0,
                'step': 1,
                'messageId': 'old-a$i',
                'text': '旧回复 $i',
              },
            },
          ],
          ..._runningEvents(completedTools: 3, startSeq: 100),
        ],
      ),
    );
    final pos = tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ))
        .position;
    // 懒构建 extent 会随构建修正：先收敛到真实底部，确保运行工具行真的可见。
    // 触发一次真实滚动事件，让首帧后挂载的过程行 key 参与几何判断。
    pos.jumpTo(pos.maxScrollExtent - 1);
    await tester.pump(const Duration(milliseconds: 120));
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(_activityBarToolsKey), findsNothing,
        reason: '仍在底部时工具可见 → 不重复');
    pos.jumpTo(pos.maxScrollExtent * 0.5);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(_activityBarToolsKey),
      findsOneWidget,
      reason: '离开底部后活动条作为固定状态提醒恢复',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });
  testWidgets('目标工具行真实离屏（<50 行、无分批）：活动条按名称保留且数量正确', (tester) async {
    // 8 行过程内容 + 稍高视口：maxScrollExtent 与 5 行用例量级一致，目标行在底部
    // 确实离屏，但滚回 150px（仍在 160px 贴底阈值内）即可进入视口。
    tester.view.physicalSize = const Size(2400, 2781);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = _runningToolAboveEvents();
    await _pumpChat(tester, _Backend(events: events));
    final pos = tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ))
        .position;
    // 收敛到真实底部（保持贴底），并触发一次滚动重建。
    pos.jumpTo(pos.maxScrollExtent - 1);
    await tester.pump(const Duration(milliseconds: 120));
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 120));

    // 目标行（long-shell）在过程块内，但视口底部只看得到后续已结束工具。
    final target = find.text('shell');
    expect(target, findsOneWidget);
    final targetBox = tester.renderObject<RenderBox>(target);
    final viewportFinder = find.byType(CustomScrollView);
    final viewportBox = tester.renderObject<RenderBox>(viewportFinder);
    final targetRect = targetBox.localToGlobal(Offset.zero) & targetBox.size;
    final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    expect(targetRect.overlaps(viewportRect), isFalse,
        reason: '用例前提：目标工具行必须在视口外（$targetRect vs $viewportRect）');
    // 且不是靠“>50 行分批隐藏”伪装：总 process 行数 < 50。
    expect(events.where((e) => e['type'] == 'tool/call').length, lessThan(50));

    // 活动条必须包含 shell，且只有这一个运行中工具（数量正确）。
    final barTools = find.byKey(_activityBarToolsKey);
    expect(barTools, findsOneWidget);
    expect(
      find.descendant(of: barTools, matching: find.textContaining('shell')),
      findsOneWidget,
      reason: '离屏运行工具必须出现在活动条（按名称）',
    );
    expect(
      find.descendant(of: barTools, matching: find.textContaining('bash')),
      findsNothing,
      reason: '已结束工具不得混入活动条',
    );
    expect(
      find.descendant(of: barTools, matching: find.textContaining('Running 1 tools')),
      findsNothing,
    );

    // 滚动目标进入视口（仍在贴底阈值内）：活动条不得再包含 shell。
    pos.jumpTo(pos.maxScrollExtent - 150);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final visibleRect =
        tester.renderObject<RenderBox>(target).localToGlobal(Offset.zero) &
        tester.renderObject<RenderBox>(target).size;
    final viewportRect2 =
        tester.renderObject<RenderBox>(viewportFinder).localToGlobal(Offset.zero) &
        tester.renderObject<RenderBox>(viewportFinder).size;
    expect(visibleRect.overlaps(viewportRect2), isTrue,
        reason: '滚动后目标行应与视口相交');
    expect(
      find.descendant(
        of: find.byKey(_activityBarToolsKey),
        matching: find.textContaining('shell'),
      ),
      findsNothing,
      reason: '目标可见后活动条不得再重复 long-shell',
    );
    await tester.pump(const Duration(milliseconds: 900));
  });



}
