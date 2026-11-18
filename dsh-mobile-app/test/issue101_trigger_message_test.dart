// issue #101：子代理/团队触发的 user/message（agent-message/team-message）普通模式显示
// 紧凑触发卡，位于过程块之前；其他系统注入隐藏（debug 全可见）；展开/空文本/重复 id/320。

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

const _session = 'session-101';

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue101.test'
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

List<Map<String, dynamic>> _fixture({
  bool includeHidden = true,
  bool duplicateAgent = false,
  bool emptyAgent = false,
}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) =>
      events.add({'seq': seq++, 'type': type, 'data': data});
  add('turn/start', {'turn': 1});
  add('user/message', {
    'messageId': 'agent-1',
    'text': emptyAgent ? '' : '请处理这个子任务\n第二行正文不应默认显示',
    'sourceKind': 'agent-message',
  });
  if (duplicateAgent) {
    add('user/message', {
      'messageId': 'agent-1',
      'text': '请处理这个子任务\n第二行正文不应默认显示',
      'sourceKind': 'agent-message',
    });
  }
  if (includeHidden) {
    for (final kind in [
      'agent-instructions',
      'runtime-context',
      'skill-catalog',
      'tool',
      'plugin',
      'subagent-settled',
    ]) {
      add('user/message', {
        'messageId': 'hidden-$kind',
        'text': '内部注入 $kind',
        'sourceKind': kind,
      });
    }
  }
  add('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'c-agent',
    'name': 'tool_agent',
    'arguments': '{}',
  });
  add('tool/result', {
    'turn': 1,
    'step': 1,
    'callId': 'c-agent',
    'name': 'tool_agent',
    'text': 'ok',
  });
  add('assistant/message', {
    'turn': 1,
    'step': 1,
    'messageId': 'a-agent',
    'text': '子代理结果',
  });
  add('turn/end', {'turn': 1, 'reason': {'kind': 'completed'}});

  add('turn/start', {'turn': 2});
  add('user/message', {
    'messageId': 'team-1',
    'text': '团队消息正文',
    'sourceKind': 'team-message',
  });
  add('tool/call', {
    'turn': 2,
    'step': 1,
    'callId': 'c-team',
    'name': 'tool_team',
    'arguments': '{}',
  });
  add('tool/result', {
    'turn': 2,
    'step': 1,
    'callId': 'c-team',
    'name': 'tool_team',
    'text': 'ok',
  });
  add('assistant/message', {
    'turn': 2,
    'step': 1,
    'messageId': 'a-team',
    'text': '团队结果',
  });
  add('turn/end', {'turn': 2, 'reason': {'kind': 'completed'}});
  return events;
}

Future<void> _pump(
  WidgetTester tester,
  _Backend backend, {
  bool debug = false,
  Size size = const Size(420, 1400),
  double textScale = 1.0,
  bool dark = false,
  bool expandedSteps = false,
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
    ..timelineDebug = debug
    ..stepDisplayMode = expandedSteps
        ? WorkStepDisplayMode.expanded
        : WorkStepDisplayMode.standard;
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
}

void main() {
  testWidgets('普通模式：agent/team 触发卡显示，其他注入隐藏，且在过程块之前', (tester) async {
    await _pump(
      tester,
      _Backend(events: _fixture()),
      expandedSteps: true,
    );
    expect(find.text('收到任务消息'), findsOneWidget);
    expect(find.text('收到团队消息'), findsOneWidget);
    for (final noise in [
      '系统指令注入',
      '插件注入',
      '工具注入',
      '系统注入',
    ]) {
      expect(find.textContaining(noise), findsNothing, reason: '$noise 普通模式应隐藏');
    }
    expect(find.text('内部注入 tool'), findsNothing);

    final agentY = tester.getTopLeft(find.text('收到任务消息')).dy;
    final teamY = tester.getTopLeft(find.text('收到团队消息')).dy;
    final toolAY = tester.getTopLeft(find.textContaining('tool_agent')).dy;
    final toolBY = tester.getTopLeft(find.textContaining('tool_team')).dy;
    expect(agentY, lessThan(toolAY), reason: '触发卡在其轮次过程块之前');
    expect(teamY, lessThan(toolBY));
  });

  testWidgets('点按展开正文，再点收起；首行默认预览', (tester) async {
    await _pump(tester, _Backend(events: _fixture()));
    expect(find.text('第二行正文不应默认显示'), findsNothing);
    expect(find.text('请处理这个子任务'), findsOneWidget); // 首行预览
    await tester.tap(find.text('收到任务消息'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('第二行正文不应默认显示'), findsOneWidget);
    await tester.tap(find.text('收到任务消息'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('第二行正文不应默认显示'), findsNothing);
  });

  testWidgets('debug 模式仍显示全部系统注入', (tester) async {
    await _pump(tester, _Backend(events: _fixture()), debug: true);
    expect(find.text('收到任务消息'), findsOneWidget);
    expect(find.textContaining('系统指令注入'), findsWidgets);
    expect(find.textContaining('工具注入'), findsWidgets);
  });

  testWidgets('空文本显示标签+无预览', (tester) async {
    await _pump(
      tester,
      _Backend(events: _fixture(emptyAgent: true)),
    );
    expect(find.text('收到任务消息'), findsOneWidget);
    final card = find.byKey(const Key('injected-agent-1'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byType(Text)).evaluate().length,
      1,
      reason: '空文本只有标签，无预览/正文',
    );
  });

  testWidgets('重复 messageId 只显示一次', (tester) async {
    await _pump(
      tester,
      _Backend(events: _fixture(duplicateAgent: true)),
    );
    expect(find.text('收到任务消息'), findsOneWidget);
    expect(find.byKey(const Key('injected-agent-1')), findsOneWidget);
  });

}
