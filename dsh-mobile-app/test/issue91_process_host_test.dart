// issue #91：同 turn 内插话把过程块切段后，宿主位置必须仍在插话之后/所属过程行附近，
// 不能前移到插话 user 之前或丢失。
//
// 最小 fixture 按 note 2445（session 222…）抽取：turn220 内 step1 工具 → 用户插话
// 「另外…」→ step2/23 工具 → 插话 user「你没有…」→ step24 工具 → 最终回答。

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

const _session = 'session-91';

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue91.test'
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
        final preceding = events.where((e) => (e['seq'] as int) < before).toList();
        final page = preceding.length > limit
            ? preceding.sublist(preceding.length - limit)
            : preceding;
        body = {'ok': true, 'events': page, 'hasMore': preceding.length > page.length};
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else {
        final tail = events.length > limit ? events.sublist(events.length - limit) : events;
        body = {'ok': true, 'events': tail, 'hasMore': events.length > tail.length};
      }
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (request.url.path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else if (request.url.path == '/m/api/command' ||
        request.url.path == '/m/api/commands' ||
        request.url.path == '/m/api/skills') {
      body = {'ok': true, 'commands': <Object>[], 'skills': <Object>[]};
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

List<Map<String, dynamic>> _fixture() {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  int add(String type, Map<String, dynamic> data) {
    final s = seq++;
    events.add({'seq': s, 'type': type, 'data': data});
    return s;
  }
  add('turn/start', {'turn': 1});
  // 提示词是 agent-message（非真人，note 2445 的 seq 13360 类型），不能当成插话。
  add('user/message', {'messageId': 'prompt', 'text': 'Team message', 'sourceKind': 'agent-message'});
  // step1：首次插话之前的过程
  add('tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'tool_before', 'arguments': 'ls'});
  add('tool/result', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'tool_middle', 'text': 'ok'});
  // 插话 1
  add('user/message', {'messageId': 'u-a', 'text': '另外还有一个要求', 'sourceKind': 'user'});
  // 插话后的 step2/step23 过程
  add('tool/call', {'turn': 1, 'step': 2, 'callId': 'c2', 'name': 'tool_middle', 'arguments': 'echo 2'});
  add('tool/result', {'turn': 1, 'step': 2, 'callId': 'c2', 'name': 'tool_middle', 'text': 'ok'});
  // 插话 2（插话发生在 tool/call/result 之间，fixture 保持 call 已在前面）
  add('user/message', {'messageId': 'u-b', 'text': '你没有ui设计子代理吗', 'sourceKind': 'user'});
  // 插话后的 step24 过程
  add('tool/call', {'turn': 1, 'step': 24, 'callId': 'c24', 'name': 'tool_after', 'arguments': '{}'});
  add('tool/result', {'turn': 1, 'step': 24, 'callId': 'c24', 'name': 'job_kill', 'text': 'ok'});
  add('assistant/message', {'turn': 1, 'step': 24, 'messageId': 'a-final', 'text': '有，已交给 ui-designer'});
  add('turn/end', {'turn': 1, 'reason': {'kind': 'completed'}});
  return events;
}


/// issue #95：中间段只有思考（无工具/助手条目），下一项是插话 user B。
/// 过程块必须锚在 B 之前，不能跨 B 前移/后移。
List<Map<String, dynamic>> _reasoningOnlyFixture() {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) =>
      events.add({'seq': seq++, 'type': type, 'data': data});
  add('turn/start', {'turn': 1});
  add('user/message', {'messageId': 'prompt', 'text': 'Team message', 'sourceKind': 'agent-message'});
  add('tool/call', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'tool_before', 'arguments': 'ls'});
  add('tool/result', {'turn': 1, 'step': 1, 'callId': 'c1', 'name': 'tool_before', 'text': 'ok'});
  add('user/message', {'messageId': 'u-a', 'text': '插话 A', 'sourceKind': 'user'});
  add('assistant/message', {
    'turn': 1,
    'step': 2,
    'reasoning': '只思考了一段',
    'reasoningChars': 7,
    'text': '',
  });
  add('user/message', {'messageId': 'u-b', 'text': '插话 B', 'sourceKind': 'user'});
  add('tool/call', {'turn': 1, 'step': 3, 'callId': 'c3', 'name': 'tool_after', 'arguments': '{}'});
  add('tool/result', {'turn': 1, 'step': 3, 'callId': 'c3', 'name': 'tool_after', 'text': 'ok'});
  add('assistant/message', {'turn': 1, 'step': 3, 'messageId': 'a-final', 'text': '最终回答'});
  add('turn/end', {'turn': 1, 'reason': {'kind': 'completed'}});
  return events;
}

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode;
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 120));
  return store;
}

void main() {
  Future<void> pumpWithTallView(
    WidgetTester tester, {
    WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _Backend(events: _fixture()), mode: mode);
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('插话后过程块宿主顺序：插话前 → 插话1后 → 插话2后（无丢失）', (tester) async {
    await pumpWithTallView(tester);
    final summaries = find.text('1 次工具调用');
    expect(summaries, findsNWidgets(3), reason: '三段各一次工具调用，不得丢失');
    final ys = [
      for (var i = 0; i < 3; i++) tester.getTopLeft(summaries.at(i)).dy,
    ];
    final userA = tester.getTopLeft(find.text('另外还有一个要求')).dy;
    final userB = tester.getTopLeft(find.text('你没有ui设计子代理吗')).dy;
    final finalAnswer = tester.getTopLeft(find.textContaining('有，已交给')).dy;
    expect(ys[0], lessThan(userA), reason: '插话1之前的过程应在 A 之前');
    expect(userA, lessThan(ys[1]), reason: '插话1后的过程必须在 A 之后');
    expect(ys[1], lessThan(userB), reason: '第二段过程应在插话2之前');
    expect(userB, lessThan(ys[2]), reason: '插话2后的过程必须在 B 之后');
    expect(ys[2], lessThan(finalAnswer), reason: '最后一段过程在最终回答之前');
  });

  testWidgets('展开档：三个工具行都在且跟随所属插话；折叠后宿主不变', (tester) async {
    await pumpWithTallView(tester, mode: WorkStepDisplayMode.expanded);
    final before = tester.getTopLeft(find.text('tool_before')).dy;
    final middle = tester.getTopLeft(find.text('tool_middle')).dy;
    final after = tester.getTopLeft(find.text('tool_after')).dy;
    final userA = tester.getTopLeft(find.text('另外还有一个要求')).dy;
    final userB = tester.getTopLeft(find.text('你没有ui设计子代理吗')).dy;
    expect(before, lessThan(userA));
    expect(userA, lessThan(middle));
    expect(middle, lessThan(userB));
    expect(userB, lessThan(after), reason: '插话2后的工具块不得前移到 B 之前');

    // 折叠第一段组抬头：只影响该段内容，不改变宿主顺序/其他段位置。
    final headers = find.text('1 次工具调用');
    if (headers.evaluate().isNotEmpty) {
      await tester.tap(headers.first);
      await tester.pump(const Duration(milliseconds: 150));
    }
    final userA2 = tester.getTopLeft(find.text('另外还有一个要求')).dy;
    final middle2 = tester.getTopLeft(find.text('tool_middle')).dy;
    expect(middle2, greaterThan(userA2), reason: '折叠/展开不得改变 host 顺序');
  });
  testWidgets('issue #95：纯思考中间段宿主落在段末之后的 user 之前（不跨消息）', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pumpChat(tester, _Backend(events: _reasoningOnlyFixture()), mode: WorkStepDisplayMode.expanded);
    await tester.pump(const Duration(milliseconds: 200));
    final userA = tester.getTopLeft(find.text('插话 A')).dy;
    final userB = tester.getTopLeft(find.text('插话 B')).dy;
    final thinking = find.textContaining('思考');
    expect(thinking, findsOneWidget, reason: '纯思考段必须仍渲染过程块');
    final thinkingY = tester.getTopLeft(thinking).dy;
    expect(thinkingY, greaterThan(userA), reason: '思考段在插话 A 之后');
    expect(thinkingY, lessThan(userB), reason: '思考段不得落到插话 B 之后（不跨用户消息）');
    final afterTool = tester.getTopLeft(find.text('tool_after')).dy;
    expect(afterTool, greaterThan(userB), reason: '后续工具段仍在 B 之后');
  });

}
