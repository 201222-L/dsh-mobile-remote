// issue #52（ADR 0027 §2）：真实对话页上的轮次过程折叠 / 展示模式 / 轮次页脚集成测试。
//
// 只断言用户可观察行为：默认折叠态、手动展开、强制展开、收起时机、页脚用时与
// 「旧宿主无 time 不显示用时」、单轮 >50 行分批。

import 'dart:async';
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
  _Backend({
    required this.events,
    this.detailEvents = const {},
    this.returnAllOnInitial = false,
  });

  final List<Map<String, dynamic>> events;

  /// `/api/event-detail` 的按 seq 响应（用于验证过程块内工具卡的详情刷新）。
  final Map<int, Map<String, dynamic>> detailEvents;

  /// 初始窗口是否忽略 limit 返回全部事件（只用于单轮 >50 行的分批用例；
  /// 其它用例保持真实分页语义）。
  final bool returnAllOnInitial;
  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue52.test'
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

  int beforePages = 0;
  int detailRequests = 0;

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    if (request.url.path == '/m/api/history') {
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('before')) {
        beforePages++;
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final preceding = events
            .where((e) => (e['seq'] as int) < before)
            .toList();
        final page = preceding.length > limit
            ? preceding.sublist(preceding.length - limit)
            : preceding;
        body = {'ok': true, 'events': page, 'hasMore': preceding.length > page.length};
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else if (returnAllOnInitial) {
        body = {'ok': true, 'events': events, 'hasMore': false};
      } else {
        final tail =
            events.length > limit ? events.sublist(events.length - limit) : events;
        body = {'ok': true, 'events': tail, 'hasMore': events.length > tail.length};
      }
    } else if (request.url.path == '/m/api/event-detail') {
      detailRequests++;
      // Api.eventDetail 期望 {ok:true, event:{type,...}}；未配置的 seq 视为不存在。
      final seq = int.tryParse(request.url.queryParameters['seq'] ?? '') ?? -1;
      final event = detailEvents[seq];
      body = event == null
          ? {
              'ok': false,
              'error': {'code': 'event-not-found'},
            }
          : {'ok': true, 'event': event};
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

const _reasoningText = '先看目录\n再跑测试';

List<Map<String, dynamic>> oneTurn({
  int turn = 1,
  String? endKind = 'completed',
  bool withTime = true,
  int startTime = 1000,
  int endTime = 4500,
}) =>
    [
      {
        'seq': 1,
        'type': 'turn/start',
        'data': {'turn': turn},
        if (withTime) 'time': startTime,
      },
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u$turn', 'text': '问题 $turn', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': turn,
          'step': 1,
          'messageId': 'a$turn-1',
          'text': '',
          'reasoning': _reasoningText,
          'reasoningChars': _reasoningText.length,
        },
        if (withTime) 'time': startTime + 300,
      },
      {
        'seq': 4,
        'type': 'tool/call',
        'data': {
          'turn': turn,
          'step': 1,
          'callId': 'call-$turn',
          'name': 'shell',
          'arguments': 'ls',
        },
        if (withTime) 'time': startTime + 500,
      },
      {
        'seq': 5,
        'type': 'tool/result',
        'data': {
          'turn': turn,
          'step': 1,
          'callId': 'call-$turn',
          'name': 'shell',
          'text': 'ok',
        },
        if (withTime) 'time': startTime + 900,
      },
      {
        'seq': 6,
        'type': 'assistant/message',
        'data': {
          'turn': turn,
          'step': 1,
          'messageId': 'a$turn-2',
          'text': '最终回答 $turn',
        },
        if (withTime) 'time': startTime + 1200,
      },
      {
        'seq': 7,
        'type': 'turn/end',
        'data': {'turn': turn, 'reason': {'kind': endKind}},
        if (withTime) 'time': endTime,
      },
    ];

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  TurnFoldTiming timing = TurnFoldTiming.afterAnswer,
}) async {
  final store = AppStore()
    ..sessionId = 'session-52'
    ..sessions = [
      Session(id: 'session-52', title: 'S', cwd: null, createdAt: 1),
    ]
    ..stepDisplayMode = mode
    ..turnFoldTiming = timing;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        // 每次 pump 用新 key：同一测试里切换展示模式要重建状态（否则沿用上一次的 store）。
        key: ValueKey('issue52-chat-${mode.name}-${timing.name}-${backend.hashCode}'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

void main() {
  testWidgets('单轮过程行 >50：分批展示并可「显示更多」', (tester) async {
    final events = <Map<String, dynamic>>[
      {
        'seq': 1,
        'type': 'turn/start',
        'data': {'turn': 1},
        'time': 1000,
      },
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '跑一堆工具', 'sourceKind': 'user'},
      },
      for (var i = 0; i < 60; i++) ...[
        {
          'seq': 10 + i * 2,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'bulk-$i',
            'name': 'shell',
            'arguments': 'echo $i',
          },
          'time': 1100 + i,
        },
        {
          'seq': 11 + i * 2,
          'type': 'tool/result',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'bulk-$i',
            'name': 'shell',
            'text': 'ok $i',
          },
          'time': 1101 + i,
        },
      ],
      {
        'seq': 500,
        'type': 'assistant/message',
        'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '全部完成'},
        'time': 2000,
      },
      {
        'seq': 501,
        'type': 'turn/end',
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
        'time': 2500,
      },
    ];
    await _pumpChat(
      tester,
      _Backend(events: events, returnAllOnInitial: true),
      mode: WorkStepDisplayMode.expanded,
    );

    // 过程块在提示词之后、位于窗口上方：往上滚到它进入构建范围。
    var found = false;
    for (var i = 0; i < 40 && !found; i++) {
      found = find.textContaining('显示更多（还有 10 行）').evaluate().isNotEmpty;
      if (found) break;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 120));
    }
    // 完全展开：整轮与过程行默认展开，但单轮只先渲染 50 行。
    await tester.ensureVisible(find.textContaining('显示更多（还有 10 行）'));
    await tester.pumpAndSettle();
    expect(find.text('shell'), findsNWidgets(processBatchSize));
    expect(find.textContaining('显示更多（还有 10 行）'), findsOneWidget);

    await tester.tap(find.textContaining('显示更多（还有 10 行）'));
    await tester.pumpAndSettle();
    expect(find.text('shell'), findsNWidgets(60));
    expect(find.textContaining('显示更多'), findsNothing);
  });

  testWidgets('详细档运行中：过程行平铺不分组，完成后（展开）才出现组抬头', (tester) async {
    // 运行中（无 turn/end）：stepGrouping=history 表示运行中不分组。
    final running = oneTurn()..removeWhere((e) => e['type'] == 'turn/end');
    await _pumpChat(
      tester,
      _Backend(events: running),
      mode: WorkStepDisplayMode.detailed,
    );
    expect(find.text('1 次工具调用'), findsNothing, reason: '运行中不出现过程组抬头');
    expect(find.text('shell'), findsOneWidget, reason: '过程行平铺可见');

    // 已完成：详细档仍自动折叠整轮；手动展开后按组呈现（组抬头出现）。
    await _pumpChat(
      tester,
      _Backend(events: oneTurn()),
      mode: WorkStepDisplayMode.detailed,
    );
    expect(find.text('1 次工具调用'), findsNothing);
    await tester.tap(find.textContaining('1 组 · 1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('1 次工具调用'), findsOneWidget);
  });

  testWidgets('过程块内工具卡加载详情后即时刷新（计划不缓存旧条目）', (tester) async {
    final events = oneTurn();
    // 工具结果事件声明详情指针（allow-list 类型），详情响应给一段比摘要更长的正文。
    final result = events.firstWhere((e) => e['type'] == 'tool/result');
    result['detail'] = {'available': true, 'seq': result['seq']};
    final backend = _Backend(
      events: events,
      detailEvents: {
        result['seq'] as int: {
          'seq': result['seq'],
          'type': 'tool/result',
          'data': {
            'callId': 'call-1',
            'name': 'shell',
            'isError': false,
            'text': 'FULL-TOOL-DETAIL',
          },
        },
      },
    );
    await _pumpChat(tester, backend, mode: WorkStepDisplayMode.expanded);

    // 过程块内工具卡（默认收起）展开后触发详情加载。
    expect(backend.api.timelineCapabilities.detail, isTrue);
    expect(find.textContaining('FULL-TOOL-DETAIL'), findsNothing);
    await tester.tap(find.text('shell'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(backend.detailRequests, greaterThan(0), reason: '展开工具卡应触发详情请求');
    expect(find.textContaining('FULL-TOOL-DETAIL'), findsOneWidget,
        reason: '详情加载后过程块内（计划解析到的当前条目）必须刷新');
  });

  testWidgets('页脚反馈 toggle 即时刷新高亮（计划不缓存旧条目）', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn()));
    expect(find.byTooltip('好的回答'), findsOneWidget);
    await tester.tap(find.byTooltip('好的回答'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byTooltip('好的回答（已选，点此取消）'), findsOneWidget,
        reason: '反馈更新后页脚操作栏必须反映新评级');
  });

  testWidgets('标准档默认：已完成轮折叠成一行摘要，不构建工具子项', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn()));

    expect(find.textContaining('1 组 · 1 次工具调用'), findsOneWidget);
    // 工具卡与最终回答都还在；折叠只收起「过程」，不影响最终回答与页脚。
    expect(find.textContaining('最终回答 1'), findsOneWidget);
    expect(find.text('shell'), findsNothing);
    expect(find.textContaining('已完成 · 用时 3.5 秒'), findsOneWidget);
  });

  testWidgets('手动展开整轮 → 过程组抬头；再展开组 → 工具卡出现', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn()));

    await tester.tap(find.textContaining('1 组 · 1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('1 次工具调用'), findsOneWidget);
    // 标准档组默认折叠：抬头可见，工具卡仍不渲染。
    expect(find.text('shell'), findsNothing);

    await tester.tap(find.text('1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('错误轮强制展开：不看策略，且页脚不显示用时', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn(endKind: 'error')));

    // 未手动操作也应直接看到过程组抬头（强制展开）。
    expect(find.text('1 次工具调用'), findsOneWidget);
    expect(find.textContaining('出错'), findsOneWidget);
    expect(find.textContaining('用时'), findsNothing);
  });

  testWidgets('旧宿主无 time：页脚只有「已完成」，不显示用时', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn(withTime: false)));

    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('用时'), findsNothing);
  });

  testWidgets('收起时机「下次有新消息」：完成轮保持展开，直到新消息到达', (tester) async {
    // 只有一轮、且没有后续 user 消息 → 不收起（与「回答结束后」档的默认折叠相反）。
    await _pumpChat(
      tester,
      _Backend(events: oneTurn()),
      timing: TurnFoldTiming.onNewMessage,
    );
    // 展开态仍保留「收起」入口（整轮摘要行），但过程组抬头已经出现。
    expect(find.text('1 次工具调用'), findsOneWidget);
  });

  testWidgets('收起时机「下次有新消息」：下一轮用户消息出现后上一轮收起', (tester) async {
    final events = [
      ...oneTurn(turn: 1),
      {
        'seq': 8,
        'type': 'turn/start',
        'data': {'turn': 2},
        'time': 6000,
      },
      {
        'seq': 9,
        'type': 'user/message',
        'data': {'messageId': 'u2', 'text': '第二个问题', 'sourceKind': 'user'},
      },
    ];
    await _pumpChat(
      tester,
      _Backend(events: events),
      timing: TurnFoldTiming.onNewMessage,
    );
    // 第 1 轮结束后出现新的 user 消息 → 第 1 轮收起（第 2 轮仍在跑，保持展开）。
    expect(find.textContaining('1 组 · 1 次工具调用'), findsOneWidget);
  });

  testWidgets('详细档：已完成轮仍被折叠（foldCompletedTurns=true）', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: oneTurn()),
      mode: WorkStepDisplayMode.detailed,
    );
    // 整轮默认收起 → 只有一行摘要，过程组抬头不出现。
    expect(find.textContaining('1 组 · 1 次工具调用'), findsOneWidget);
    expect(find.text('1 次工具调用'), findsNothing);

    // 手动展开后按组呈现，过程组默认折叠（组抬头出现）。
    await tester.tap(find.textContaining('1 组 · 1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('1 次工具调用'), findsOneWidget);
    expect(find.text('shell'), findsNothing);
  });

  testWidgets('完全展开档：已完成轮不折叠且工具卡仍默认收起', (tester) async {
    await _pumpChat(
      tester,
      _Backend(events: oneTurn()),
      mode: WorkStepDisplayMode.expanded,
    );
    // 不折叠、不分组的档位（stepGrouping=none）：整轮直接铺开过程行。
    expect(find.text('1 次工具调用'), findsNothing); // 没有过程组抬头
    expect(find.text('shell'), findsOneWidget); // 工具卡行在
    expect(find.text('参数'), findsNothing); // 单卡仍默认收起

    await tester.tap(find.text('shell'));
    await tester.pumpAndSettle();
    expect(find.text('参数'), findsOneWidget);
  });

  testWidgets('完全展开档运行中：过程行仍显示，只是不分组（liveProcessDetail 不隐藏行）', (
    tester,
  ) async {
    final events = oneTurn()..removeWhere((e) => e['type'] == 'turn/end');
    await _pumpChat(
      tester,
      _Backend(events: events),
      mode: WorkStepDisplayMode.expanded,
    );
    // stepGrouping=none：运行中也没有过程组抬头，过程行直接平铺。
    expect(find.text('正在调用工具…'), findsNothing);
    expect(find.text('1 次工具调用'), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('标准档运行中：按组且组强制展开，抬头附带当前工具名', (tester) async {
    // issue #61：抬头只信真实运行态——必须留一条未回结果的工具调用（只有 call 无 result）。
    final events = oneTurn()
      ..removeWhere(
        (e) => e['type'] == 'turn/end' || e['type'] == 'tool/result',
      );
    await _pumpChat(tester, _Backend(events: events));
    expect(find.text('正在调用工具…（shell）'), findsOneWidget);
    expect(find.text('shell'), findsOneWidget); // 组强制展开 → 工具行可见
  });

  testWidgets('简洁档运行中：行仍在，抬头只给通用文案（无工具名）', (tester) async {
    final events = oneTurn()
      ..removeWhere(
        (e) => e['type'] == 'turn/end' || e['type'] == 'tool/result',
      );
    await _pumpChat(
      tester,
      _Backend(events: events),
      mode: WorkStepDisplayMode.concise,
    );
    expect(find.text('正在调用工具…'), findsOneWidget);
    expect(find.textContaining('（shell）'), findsNothing);
    expect(find.text('shell'), findsOneWidget);
  });

  testWidgets('手动展开只存内存：本会话内重建保持，重新进入会话按策略重算', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: oneTurn()));
    await tester.tap(find.textContaining('1 组 · 1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('1 次工具调用'), findsOneWidget);

    // 设置变化触发整页重建（等价于切页返回后重绘）：手动展开仍在内存中。
    unawaited(store.setShowReasoning(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('1 次工具调用'), findsOneWidget);

    // 离开并重新进入会话（新页面状态）：按策略恢复默认折叠。
    await _pumpChat(tester, _Backend(events: oneTurn()));
    expect(find.text('1 次工具调用'), findsNothing);
    expect(find.textContaining('1 组 · 1 次工具调用'), findsOneWidget);
  });

  testWidgets('过程块位于用户提问之后：提问 → 本轮过程 → 回答', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn()));
    final promptY = tester.getTopLeft(find.text('问题 1')).dy;
    final processY =
        tester.getTopLeft(find.textContaining('1 组 · 1 次工具调用')).dy;
    final answerY = tester.getTopLeft(find.textContaining('最终回答 1')).dy;
    expect(promptY, lessThan(processY));
    expect(processY, lessThan(answerY));
  });

  testWidgets('轮内插话：过程行在插话处切成两段，各自折叠', (tester) async {
    final events = <Map<String, dynamic>>[
      {
        'seq': 1,
        'type': 'turn/start',
        'data': {'turn': 1},
        'time': 1000,
      },
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'shell',
          'arguments': 'ls',
        },
        'time': 1100,
      },
      {
        'seq': 4,
        'type': 'tool/result',
        'data': {'turn': 1, 'step': 1, 'callId': 'c1', 'text': 'ok'},
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
          'arguments': '{}',
        },
        'time': 1300,
      },
      {
        'seq': 7,
        'type': 'tool/result',
        'data': {'turn': 1, 'step': 2, 'callId': 'c2', 'text': 'ok'},
        'time': 1400,
      },
      {
        'seq': 8,
        'type': 'assistant/message',
        'data': {'turn': 1, 'step': 2, 'messageId': 'a1', 'text': '回答'},
        'time': 1500,
      },
      {
        'seq': 9,
        'type': 'turn/end',
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
        'time': 2000,
      },
    ];
    await _pumpChat(tester, _Backend(events: events));
    // 轮内有插话 → 强制展开（不吃策略）：issue #61 起展开态不再显示整轮摘要行，
    // 改为两段各自的组抬头（标准档已完成轮的组默认折叠）。
    expect(find.textContaining('组 · 1 次工具调用'), findsNothing);
    expect(find.text('1 次工具调用'), findsNWidgets(2));
    // 过程段出现在插话之后。
    final steerY = tester.getTopLeft(find.text('插话')).dy;
    final secondY = tester.getTopLeft(find.text('1 次工具调用').last).dy;
    expect(steerY, lessThan(secondY));
  });

  testWidgets('一轮多条文字回复：页脚只出现一份操作栏', (tester) async {
    final events = <Map<String, dynamic>>[
      ...oneTurn(),
      {
        'seq': 80,
        'type': 'assistant/message',
        'data': {'turn': 1, 'step': 1, 'messageId': 'a-extra', 'text': '补充说明'},
      },
    ];
    await _pumpChat(tester, _Backend(events: events));
    expect(find.byTooltip('好的回答'), findsOneWidget);
    expect(find.byTooltip('在新对话中分支'), findsOneWidget);
  });

  testWidgets('深分页：上翻加载更早轮次后，旧页轮次与过程块真的进入列表', (tester) async {
    // 40 轮 × (turn/start + user + tool/result + assistant)：初始只给尾部 50 条，
    // 上翻经 before 分页加载更早轮次，旧页过程块必须按原位重建、内容可见。
    final events = <Map<String, dynamic>>[];
    var seq = 1;
    for (var turn = 1; turn <= 40; turn++) {
      events.add({
        'seq': seq++,
        'type': 'turn/start',
        'data': {'turn': turn},
        'time': 1000 * turn,
      });
      events.add({
        'seq': seq++,
        'type': 'user/message',
        'data': {'messageId': 'u$turn', 'text': '问题 $turn', 'sourceKind': 'user'},
      });
      events.add({
        'seq': seq++,
        'type': 'tool/call',
        'data': {
          'turn': turn,
          'step': 1,
          'callId': 'c$turn',
          'name': 'shell',
          'arguments': 'echo $turn',
        },
        'time': 1000 * turn + 100,
      });
      events.add({
        'seq': seq++,
        'type': 'tool/result',
        'data': {
          'turn': turn,
          'step': 1,
          'callId': 'c$turn',
          'name': 'shell',
          'text': 'ok $turn',
        },
        'time': 1000 * turn + 200,
      });
      events.add({
        'seq': seq++,
        'type': 'assistant/message',
        'data': {'turn': turn, 'messageId': 'a$turn', 'text': '回答 $turn'},
        'time': 1000 * turn + 500,
      });
    }
    final backend = _Backend(events: events);
    await _pumpChat(tester, backend);

    expect(find.text('回答 5'), findsNothing, reason: '第 5 轮在初始窗口之外');
    // 到顶触发无限上翻（微信式）；每次上翻后检查旧轮内容是否真的被构建出来。
    var found = false;
    for (var i = 0; i < 40 && !found; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 250));
      found = find.text('回答 5').evaluate().isNotEmpty;
    }
    expect(backend.beforePages, greaterThan(0), reason: '上翻应触发 before 分页');
    expect(found, isTrue, reason: '旧页第 5 轮必须真的进入列表（内容按分页重建）');
    // 旧页轮次的过程块同样重建（夹具无 turn/end → 强制展开 → 每轮一个组抬头）。
    expect(find.text('1 次工具调用'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页脚承载消息操作：复制/反馈/分支从助手气泡迁移', (tester) async {
    await _pumpChat(tester, _Backend(events: oneTurn()));

    // 轮次页脚内应有四个操作图标（复制/赞/踩/分支）：助手气泡内不再重复，
    // 唯一的另一个「复制」是 user 气泡（issue #15 保留的独立入口）。
    expect(find.byTooltip('复制'), findsNWidgets(2));
    expect(find.byTooltip('好的回答'), findsOneWidget);
    expect(find.byTooltip('有问题的回答'), findsOneWidget);
    expect(find.byTooltip('在新对话中分支'), findsOneWidget);
  });
}
