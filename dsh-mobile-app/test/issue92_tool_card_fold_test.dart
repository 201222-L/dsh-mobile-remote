// issue #92：压缩回放（compaction prune 后重新落盘的旧 turn tool/result）没有 turn/start，
// 无法进入 TurnProcess，旧逻辑回退成独立工具卡，出现在当前轮“收起过程”之后。
// 修复目标：这类无法归组的历史工具结果必须有明确 fallback 语义且可折叠，不能伪装成
// 当前过程行/独立旧卡片。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-92';

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue92.test'
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
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
    } else if (path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else if (path == '/m/api/commands' || path == '/m/api/skills') {
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
  void add(String type, Map<String, dynamic> data) =>
      events.add({'seq': seq++, 'type': type, 'data': data});
  add('turn/start', {'turn': 220});
  add('user/message', {'messageId': 'u1', 'text': '开始', 'sourceKind': 'user'});
  add('tool/call', {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'arguments': 'ls'});
  add('tool/result', {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'text': 'ok'});
  // 压缩回放：旧 turn 148 的 tool/result（无 turn/start / tool/call 同屏），
  // 与 note 2445 真实事件 13283/13285/13287 同形。
  for (final row in [
    (148, 'call_00_mx03kxx6nhrcr2xruau1vg9u', 'note 2312'),
    (152, 'call_00_vv7f3ulujfbxzld14dtsbzom', 'commit c5f7e252ba069461e4ed88fd63467f30ef8fd221'),
    (197, 'call_00_l20s3d7c16mmxarc2gh7zjgy', 'if (!hasNewFileMethods(provider)) return false;'),
  ]) {
    // 服务端 /history 的规范化形状：callId/name/text 在 data 顶层。
    add('tool/result', {
      'turn': row.$1,
      'step': 1,
      'callId': row.$2,
      'name': 'bash',
      'text': row.$3,
    });
  }
  add('assistant/message', {'turn': 220, 'step': 1, 'messageId': 'a1', 'text': '最终回答'});
  add('turn/end', {'turn': 220, 'reason': {'kind': 'completed'}});
  return events;
}

Future<AppStore> _pumpChat(WidgetTester tester, _Backend backend) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 150));
  return store;
}

void main() {
  Finder toolCard(String callId) => find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('tool:$callId:'),
      );

  testWidgets('压缩回放旧工具结果：进入历史过程组、无独立旧卡片、可展开收起', (tester) async {
    await _pumpChat(tester, _Backend(events: _fixture()));
    // 当前轮 + 3 个孤儿历史工具组，各 1 个工具；每个工具只出现一次（卡片被过程块承载）。
    expect(find.text('1 组 · 1 次工具调用'), findsNWidgets(4));
    expect(find.text('历史工具结果（无过程上下文）'), findsNWidgets(3));
    expect(toolCard('call_00_mx03kxx6nhrcr2xruau1vg9u'), findsNothing);
    expect(toolCard('call_00_vv7f3ulujfbxzld14dtsbzom'), findsNothing);
    expect(toolCard('call_00_l20s3d7c16mmxarc2gh7zjgy'), findsNothing);

    // 展开其中一个历史 fallback 组：只出现该工具一次；收起后再次隐藏。
    final label = find.byKey(const Key('historical-tool-results-197'));
    expect(label, findsOneWidget);
    final block = find.ancestor(of: label, matching: find.byType(Column)).first;
    await tester.tap(
      find.descendant(of: block, matching: find.text('1 组 · 1 次工具调用')),
    );
    await tester.pump(const Duration(milliseconds: 150));
    final groupHeader = find.descendant(
      of: find.ancestor(of: label, matching: find.byType(Column)).first,
      matching: find.text('1 次工具调用'),
    );
    expect(groupHeader, findsOneWidget);
    await tester.tap(groupHeader);
    await tester.pump(const Duration(milliseconds: 150));
    expect(toolCard('call_00_l20s3d7c16mmxarc2gh7zjgy'), findsOneWidget);
    expect(toolCard('call_00_mx03kxx6nhrcr2xruau1vg9u'), findsNothing);
    await tester.tap(groupHeader);
    await tester.pump(const Duration(milliseconds: 150));
    expect(toolCard('call_00_l20s3d7c16mmxarc2gh7zjgy'), findsNothing);
  });
}
