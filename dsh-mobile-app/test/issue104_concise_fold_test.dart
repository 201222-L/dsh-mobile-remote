// issue #104：简洁模式运行中整组折叠成一行，活动条表达当前；手动展开优先于新事件/result；
// 未手动卡 result 立即保持折叠；收起/切轮复位；其他三档不回归。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-104';

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue104.test'
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
    Map<String, Object?> body;
    if (request.url.path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (request.url.path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else if (request.url.path == '/m/api/commands' ||
        request.url.path == '/m/api/skills') {
      body = {'ok': true, 'commands': <Object>[], 'skills': <Object>[]};
    } else {
      body = {'ok': true};
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

List<Map<String, dynamic>> _runningFixture({int turn = 1, String callId = 'c1'}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) =>
      events.add({'seq': seq++, 'type': type, 'data': data});
  add('turn/start', {'turn': turn});
  add('user/message', {
    'messageId': 'u$turn',
    'text': '开始',
    'sourceKind': 'user',
  });
  add('tool/call', {
    'turn': turn,
    'step': 1,
    'callId': callId,
    'name': 'bash',
    'arguments': '{"command":"ls"}',
  });
  return events;
}

Future<AppStore> _pump(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.concise,
  Size size = const Size(420, 900),
  double textScale = 1.0,
  bool dark = false,
}) async {
  L10n.lang = 'zh';
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode;
  await tester.pumpWidget(MaterialApp(
    theme: dark ? ThemeData.dark() : null,
    home: ChatScreen(
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 400));
  return store;
}

Future<void> _inject(
  WidgetTester tester,
  AppStore store,
  Map<String, dynamic> event,
) async {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': event,
  });
  await tester.pump();
  await tester.pump();
  // session 帧的 800ms debounce 计时器必须在测试结束前落地。
  await tester.pump(const Duration(seconds: 1));
}

Finder _toolCard(String callId) => find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('tool:$callId:'),
    );

Finder _summary() => find.textContaining('1 次工具调用');

void main() {
  testWidgets('简洁运行中：整组一行，不铺工具卡；result 到达仍折叠', (tester) async {
    final backend = _Backend(events: _runningFixture());
    final store = await _pump(tester, backend);
    expect(_summary(), findsOneWidget);
    expect(_toolCard('c1'), findsNothing, reason: '运行中不得铺开工具卡');

    await _inject(tester, store, {
      'seq': 4,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'c1',
        'name': 'bash',
        'text': 'ok',
      },
    });
    expect(_summary(), findsOneWidget);
    expect(_toolCard('c1'), findsNothing, reason: '未手动展开卡 result 后仍折叠');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('手动展开段一次见内容；组/卡手动状态与 result 互不抢回', (tester) async {
    final backend = _Backend(events: _runningFixture());
    final store = await _pump(tester, backend);
    await tester.tap(_summary());
    await tester.pump(const Duration(milliseconds: 150));
    // P2：一次点击摘要就应看到工具卡，不需要再点组。
    expect(_toolCard('c1'), findsOneWidget, reason: '手动展开段后内容直接可见');

    // 手动展开工具卡。
    await tester.tap(_toolCard('c1'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('callId: c1'), findsOneWidget);

    // result 到达：段/组/卡的手动展开都不得被抢回。
    await _inject(tester, store, {
      'seq': 4,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'c1',
        'name': 'bash',
        'text': 'ok',
      },
    });
    expect(_toolCard('c1'), findsOneWidget, reason: 'result 不得抢回手动展开组/卡');
    expect(find.textContaining('callId: c1'), findsOneWidget,
        reason: '手动展开的卡 result 后仍保持展开');

    // 手动收起组：后续新工具事件也不得自动展开。
    final group = find.textContaining('1 次工具调用');
    expect(group, findsOneWidget);
    await tester.tap(group);
    await tester.pump(const Duration(milliseconds: 150));
    expect(_toolCard('c1'), findsNothing);
    await _inject(tester, store, {
      'seq': 5,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'c2',
        'name': 'bash',
        'arguments': '{}',
      },
    });
    expect(_toolCard('c2'), findsNothing, reason: '手动收起后新事件不得自动展开');
  });

  testWidgets('切轮后新轮简洁仍默认一行', (tester) async {
    final backend = _Backend(events: _runningFixture());
    final store = await _pump(tester, backend);
    await tester.tap(_summary());
    await tester.pump(const Duration(milliseconds: 150));
    expect(_toolCard('c1'), findsOneWidget);

    await _inject(tester, store, {
      'seq': 4,
      'type': 'turn/end',
      'data': {'turn': 1, 'reason': {'kind': 'completed'}},
    });
    await _inject(tester, store, {
      'seq': 5,
      'type': 'turn/start',
      'data': {'turn': 2},
    });
    await _inject(tester, store, {
      'seq': 6,
      'type': 'user/message',
      'data': {'messageId': 'u2', 'text': '下一轮', 'sourceKind': 'user'},
    });
    await _inject(tester, store, {
      'seq': 7,
      'type': 'tool/call',
      'data': {
        'turn': 2,
        'step': 1,
        'callId': 'c3',
        'name': 'bash',
        'arguments': '{}',
      },
    });
    expect(_summary(), findsWidgets);
    expect(_toolCard('c3'), findsNothing, reason: '切轮后新轮默认折叠');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('v4：标准运行中组折叠不铺卡；详细/完全展开可见', (tester) async {
    // 标准：组抬头折叠，不显示工具卡（活动条承载当前状态）。
    await _pump(
      tester,
      _Backend(events: _runningFixture()),
      mode: WorkStepDisplayMode.standard,
    );
    expect(_toolCard('c1'), findsNothing);
    expect(find.textContaining('1 次工具调用 · 进行中'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    for (final mode in [
      WorkStepDisplayMode.detailed,
      WorkStepDisplayMode.expanded,
    ]) {
      final backend = _Backend(events: _runningFixture());
      await _pump(tester, backend, mode: mode);
      expect(_toolCard('c1'), findsOneWidget, reason: '$mode 运行中应显示行摘要');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('简洁 320/深色/1.5x 不溢出', (tester) async {
    await _pump(
      tester,
      _Backend(events: _runningFixture()),
      size: const Size(320, 800),
      textScale: 1.5,
      dark: true,
    );
    expect(_summary(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
