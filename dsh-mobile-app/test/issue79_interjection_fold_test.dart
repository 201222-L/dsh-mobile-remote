// issue #79：思考中插入消息后，过程块结束后无法折叠。
//
// 根因：`forceExpanded` 把「轮内插话」永久算作强制展开；结束后既不显示整轮摘要/
// 收起入口，组也无法折叠。
// 修复契约：插话只让该轮**默认展开**（可手动折叠）；运行中/aborted/interrupted/error
// 仍为硬强制展开；两档收起时机、手动覆盖、组折叠矩阵不变。

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

const _session = 'session-79';

class _Backend {
  _Backend({required this.events});

  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue79.test'
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
    if (request.url.path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
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

/// 插话轮：提示 → 思考 + step1 工具 → 真人插话（seq5）→ step2 工具 → 回答。
/// [ended]=false 表示仍在运行；[endKind] 控制结束类型；[postEndUser] 追加轮后真人消息。
List<Map<String, dynamic>> interjectionTurn({
  bool ended = true,
  String? endKind = 'completed',
  bool postEndUser = false,
  bool withReasoning = true,
}) =>
    [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '问题 1', 'sourceKind': 'user'},
        'time': 1050,
      },
      if (withReasoning)
        {
          'seq': 3,
          'type': 'assistant/message',
          'data': {
            'turn': 1,
            'step': 1,
            'messageId': 'a-r',
            'text': '',
            'reasoning': '先看目录',
            'reasoningChars': 4,
          },
          'time': 1060,
        },
      {
        'seq': 4,
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
        'seq': 5,
        'type': 'tool/result',
        'data': {'turn': 1, 'step': 1, 'callId': 'c1', 'text': 'ok'},
        'time': 1200,
      },
      // 真人插话（轮内）——seq 5 之后。
      {
        'seq': 6,
        'type': 'user/message',
        'data': {'messageId': 'u2', 'text': '插话', 'sourceKind': 'user'},
        'time': 1250,
      },
      {
        'seq': 7,
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
        'seq': 8,
        'type': 'tool/result',
        'data': {'turn': 1, 'step': 2, 'callId': 'c2', 'text': 'ok'},
        'time': 1400,
      },
      {
        'seq': 9,
        'type': 'assistant/message',
        'data': {'turn': 1, 'step': 2, 'messageId': 'a1', 'text': '回答'},
        'time': 1500,
      },
      if (ended)
        {
          'seq': 10,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': endKind},
          },
          'time': 2000,
        },
      if (postEndUser)
        {
          'seq': 11,
          'type': 'user/message',
          'data': {'messageId': 'u3', 'text': '轮后新消息', 'sourceKind': 'user'},
          'time': 2100,
        },
    ];

/// 普通完成轮（无插话，用于两档时机对照）。
List<Map<String, dynamic>> plainTurn({bool postEndUser = false}) => [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '问题', 'sourceKind': 'user'},
        'time': 1050,
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
        'type': 'assistant/message',
        'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '回答'},
        'time': 1500,
      },
      {
        'seq': 6,
        'type': 'turn/end',
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
        'time': 2000,
      },
      if (postEndUser)
        {
          'seq': 7,
          'type': 'user/message',
          'data': {'messageId': 'u2', 'text': '轮后新消息', 'sourceKind': 'user'},
          'time': 2100,
        },
    ];

Future<AppStore> _pumpChat(
  WidgetTester tester,
  List<Map<String, dynamic>> events, {
  TurnFoldTiming timing = TurnFoldTiming.afterAnswer,
  String suffix = '',
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [
      Session(id: _session, title: 'S', cwd: null, createdAt: 1),
    ]
    ..stepDisplayMode = WorkStepDisplayMode.standard
    ..turnFoldTiming = timing;
  final backend = _Backend(events: events);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue79-$suffix-${timing.name}'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  return store;
}

Finder get _groupHeaders => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ProcessGroupHeader',
    );
Finder get _summaryRows => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ProcessSummaryRow',
    );
Finder get _collapseRows => find.textContaining('收起过程');

void main() {
  testWidgets('插话轮结束后默认展开；可手动折叠并再展开', (tester) async {
    await _pumpChat(tester, interjectionTurn());
    // 默认展开：两段各自的组抬头/收起入口，没有整轮摘要。
    expect(_groupHeaders, findsNWidgets(2));
    expect(_collapseRows, findsNWidgets(2));
    expect(_summaryRows, findsNothing);

    // 折叠第一段（过程块）→ 出现该段摘要行，组抬头少一个。
    await tester.ensureVisible(_collapseRows.first);
    await tester.tap(_collapseRows.first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_summaryRows, findsOneWidget);
    expect(_groupHeaders, findsOneWidget);
    expect(find.textContaining('组 · 1 次工具调用'), findsOneWidget);

    // 点摘要重新展开。
    await tester.tap(_summaryRows);
    await tester.pump(const Duration(milliseconds: 200));
    expect(_groupHeaders, findsNWidgets(2));
    expect(_summaryRows, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('运行中插话轮仍强制展开：没有收起入口', (tester) async {
    await _pumpChat(tester, interjectionTurn(ended: false));
    expect(_groupHeaders, findsNWidgets(2));
    expect(_collapseRows, findsNothing, reason: '运行中强制展开不可折叠');
    await tester.pump(const Duration(milliseconds: 900));
  });

  testWidgets('异常结束的插话轮仍强制展开：没有收起入口', (tester) async {
    for (final kind in ['aborted', 'interrupted', 'error']) {
      await _pumpChat(
        tester,
        interjectionTurn(endKind: kind),
        suffix: kind,
      );
      expect(_groupHeaders, findsNWidgets(2), reason: kind);
      expect(_collapseRows, findsNothing, reason: '$kind 强制展开不可折叠');
      await tester.pump(const Duration(milliseconds: 900));
    }
  });

  testWidgets('两档收起时机：插话只影响 afterAnswer；onNewMessage 仍按新消息收起', (tester) async {
    // afterAnswer + 普通完成轮 → 自动收起（出现摘要）。
    await _pumpChat(tester, plainTurn(), suffix: 'plain-aa');
    expect(_summaryRows, findsOneWidget);
    expect(_groupHeaders, findsNothing);

    // onNewMessage + 普通完成轮（轮后无新消息）→ 不收起。
    await _pumpChat(
      tester,
      plainTurn(),
      timing: TurnFoldTiming.onNewMessage,
      suffix: 'plain-onm',
    );
    expect(_groupHeaders, findsOneWidget);
    expect(_summaryRows, findsNothing);

    // onNewMessage + 普通完成轮 + 轮后新消息 → 收起。
    await _pumpChat(
      tester,
      plainTurn(postEndUser: true),
      timing: TurnFoldTiming.onNewMessage,
      suffix: 'plain-onm-new',
    );
    expect(_summaryRows, findsOneWidget);

    // 插话轮 afterAnswer：回答刚结束 → 保持默认展开（可手动折叠）。
    await _pumpChat(
      tester,
      interjectionTurn(postEndUser: true),
      timing: TurnFoldTiming.afterAnswer,
      suffix: 'steer-aa',
    );
    expect(_groupHeaders, findsNWidgets(2), reason: 'afterAnswer 插话轮默认展开');
    expect(_collapseRows, findsNWidgets(2), reason: 'afterAnswer 插话轮可手动折叠');
    expect(_summaryRows, findsNothing);

    // 插话轮 onNewMessage：轮后尚无新消息 → 仍展开。
    await _pumpChat(
      tester,
      interjectionTurn(),
      timing: TurnFoldTiming.onNewMessage,
      suffix: 'steer-onm',
    );
    expect(_groupHeaders, findsNWidgets(2), reason: 'onNewMessage 无新消息 → 展开');
    expect(_collapseRows, findsNWidgets(2));
    expect(_summaryRows, findsNothing);

    // 插话轮 onNewMessage + 轮后新消息 → 正常自动收起（插话不让该档永久失效）。
    await _pumpChat(
      tester,
      interjectionTurn(postEndUser: true),
      timing: TurnFoldTiming.onNewMessage,
      suffix: 'steer-onm-new',
    );
    // 插话轮被切成两段，每段各自收起 → 两个摘要行。
    expect(_summaryRows, findsNWidgets(2),
        reason: 'onNewMessage 档：插话轮结束后出现新消息仍应自动收起');
    expect(_groupHeaders, findsNothing);
    expect(_collapseRows, findsNothing);
  });

  testWidgets('展开后过程组仍默认折叠，可逐组展开/收起', (tester) async {
    await _pumpChat(tester, interjectionTurn());
    expect(_groupHeaders, findsNWidgets(2));
    // 组默认折叠：组内工具行不可见。
    expect(find.text('shell'), findsNothing);
    await tester.tap(_groupHeaders.first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('shell'), findsOneWidget);
    await tester.tap(_groupHeaders.first);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('shell'), findsNothing);
    await tester.pump(const Duration(milliseconds: 900));
  });
}
