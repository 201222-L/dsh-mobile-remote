// issue #31 复审（note 1228）：**真实分页**下的长会话定位回归。
//
// 上一轮的回归把 3000 条事件一次性塞进初始响应，等于绕开了真实分页路径——
// 真实 App 是"初始 50 条、`before` 每页 ≤200 条"，而更早历史 prepend 进来后
// `minScrollExtent` 会向负方向大幅扩展、内容偏移变成负坐标。复审正是在这条路径上
// 复现了「24 次尝试用尽仍跳不到」。
//
// 本文件用**严格遵守 limit 的假后端**（初始尾部 50 条 / before 最多 200 条 / after 同理）
// 覆盖：冷跳远端 older 轮次、热跳同一目标、以及"10 轮 × 约 250 条目"这种真机形状。

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

/// 每轮 = turn/start + 用户消息 + 助手回复（要多少轮就有多少轮）。
List<Map<String, dynamic>> _turnEvents(int turns, {int replyRepeat = 20}) {
  final out = <Map<String, dynamic>>[];
  var seq = 1;
  for (var turn = 1; turn <= turns; turn++) {
    out.add({'seq': seq++, 'type': 'turn/start', 'data': {'turn': turn}});
    out.add({
      'seq': seq++,
      'type': 'user/message',
      'data': {'messageId': 'u$turn', 'sourceKind': 'user', 'text': '问题 $turn'},
    });
    out.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {'messageId': 'a$turn', 'turn': turn, 'text': '回答 $turn ' * replyRepeat},
    });
  }
  return out;
}

/// 真机形状：轮数少、但每轮有大量工具条目（用户那个会话就是 10 轮 / ~2967 条目）。
List<Map<String, dynamic>> _denseTurnEvents({
  int turns = 10,
  int toolsPerTurn = 250,
}) {
  final out = <Map<String, dynamic>>[];
  var seq = 1;
  for (var turn = 1; turn <= turns; turn++) {
    out.add({'seq': seq++, 'type': 'turn/start', 'data': {'turn': turn}});
    out.add({
      'seq': seq++,
      'type': 'user/message',
      'data': {'messageId': 'u$turn', 'sourceKind': 'user', 'text': '问题 $turn'},
    });
    for (var i = 1; i <= toolsPerTurn; i++) {
      out.add({
        'seq': seq++,
        'type': 'tool/result',
        'data': {'callId': 'c$turn-$i', 'name': 'shell', 'text': '工具输出 $turn-$i', 'isError': false},
      });
    }
    out.add({
      'seq': seq++,
      'type': 'assistant/message',
      'data': {'messageId': 'a$turn', 'turn': turn, 'text': '回答 $turn ' * 20},
    });
  }
  return out;
}

/// 严格遵守分页语义的假后端（初始尾部 50 条 / before 每页 ≤ limit / after 同理）。
class _PagedBackend {
  _PagedBackend({required this.events, required this.outlineTurns});

  final List<Map<String, dynamic>> events;
  final int outlineTurns;

  final List<Map<String, String>> beforeRequests = [];

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://paged.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
    )
    ..turnOutlineCapabilities = const TurnOutlineCapabilities(
      version: 1,
      supported: true,
      unloaded: true,
      truncated: true,
    );

  http.Response _json(Map<String, dynamic> body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/m/api/history') {
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      int seqOf(Map<String, dynamic> event) => event['seq'] as int;
      if (params.containsKey('before')) {
        beforeRequests.add(params);
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final preceding = events.where((e) => seqOf(e) < before).toList();
        final page = preceding.length > limit
            ? preceding.sublist(preceding.length - limit)
            : preceding;
        return _json({
          'ok': true,
          'events': page,
          'hasMore': preceding.length > page.length,
        });
      }
      if (params.containsKey('after')) {
        final after = int.tryParse(params['after'] ?? '') ?? 0;
        final following = events.where((e) => seqOf(e) > after).toList();
        final page = following.length > limit ? following.sublist(0, limit) : following;
        return _json({
          'ok': true,
          'events': page,
          'hasMore': following.length > page.length,
        });
      }
      final tail = events.length > limit ? events.sublist(events.length - limit) : events;
      return _json({
        'ok': true,
        'events': tail,
        'hasMore': events.length > tail.length,
      });
    }
    if (path == '/m/api/turn-outline') {
      return _json({
        'ok': true,
        'state': 'available',
        'asOfSeq': events.isEmpty ? -1 : events.last['seq'],
        'turns': [
          for (var turn = 1; turn <= outlineTurns; turn++)
            {
              'turn': turn,
              'seq': 1 + (turn - 1) * (events.length ~/ outlineTurns),
              'prompt': '大纲第 $turn 轮提示',
              'response': '大纲第 $turn 轮回复',
            },
        ],
      });
    }
    if (path == '/m/api/queue') return _json({'ok': true, 'rows': <Object>[]});
    if (path == '/m/api/todos') return _json({'ok': true, 'todos': <Object>[]});
    if (path == '/m/api/session-config') {
      return _json({'ok': true, 'config': <String, dynamic>{}});
    }
    return _json({'ok': true});
  }
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required _PagedBackend backend,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      store: AppStore()..sessionId = 'paged-session',
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

TurnNavigatorRail _rail(WidgetTester tester) =>
    tester.widget<TurnNavigatorRail>(find.byType(TurnNavigatorRail));

bool _textInViewport(WidgetTester tester, String text) {
  final view = tester.getRect(find.byType(CustomScrollView));
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) return false;
  return finder.evaluate().any((e) => view.overlaps(tester.getRect(finder)));
}

Future<void> _leaveBottom(WidgetTester tester) async {
  await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
  await tester.pumpAndSettle();
}

/// 点刻度轨上的某一轮；返回本次定位**实际发生的滚动落点序列**（= 探针次数）。
///
/// 分页/定位期间有脉冲动画，故用有界 pump 而不是 pumpAndSettle。
Future<List<double>> _navigate(
  WidgetTester tester,
  int turn, {
  int frames = 120,
}) async {
  final position = _position(tester);
  final offsets = <double>[];
  void record() => offsets.add(position.pixels);
  position.addListener(record);
  final anchor = _rail(tester).anchors.firstWhere((a) => a.turn == turn);
  _rail(tester).onNavigate(anchor);
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
  position.removeListener(record);
  // ignore: avoid_print
  print('PAGEDLOC turn=$turn probes=${offsets.length} offsets=$offsets '
      'pixels=${position.pixels} min=${position.minScrollExtent} max=${position.maxScrollExtent}');
  return offsets;
}

void main() {
  testWidgets('真实分页：冷跳远端 older 轮次（1000 轮 / 3000 条）', (tester) async {
    final backend = _PagedBackend(
      events: _turnEvents(1000, replyRepeat: 2),
      outlineTurns: 1000,
    );
    await _pumpChat(tester, backend: backend);
    expect(backend.beforeRequests, isEmpty, reason: '初始只拉尾部窗口');
    await _leaveBottom(tester);

    final probes = await _navigate(tester, 2);

    expect(backend.beforeRequests.length, greaterThan(5),
        reason: '跨页跳转应真的翻了多页历史（不是一次性全给）');
    expect(_textInViewport(tester, '问题 2'), isTrue,
        reason: '真实分页路径下第 2 轮必须真的进入视口（复审反例：24 次用尽仍未进入）');
    expect(tester.takeException(), isNull);
    // ignore: avoid_print
    print('PAGEDLOC coldProbes=${probes.length} beforePages=${backend.beforeRequests.length}');
  });

  testWidgets('真实分页：热跳同一目标不劣化（先离开再重跳）', (tester) async {
    final backend = _PagedBackend(
      events: _turnEvents(1000, replyRepeat: 2),
      outlineTurns: 1000,
    );
    await _pumpChat(tester, backend: backend);
    await _leaveBottom(tester);

    final cold = await _navigate(tester, 2);
    expect(_textInViewport(tester, '问题 2'), isTrue);

    // 回到列表远端（不是 reload、不清缓存），确认目标确实离开视口。
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(_textInViewport(tester, '问题 2'), isFalse,
        reason: '重跳前目标必须已经不在视口（否则测不到热缓存）');
    // 贴近底部时刻度轨会隐藏；再离开底部把它显出来（历史仍已加载、缓存未清）。
    await _leaveBottom(tester);

    final hot = await _navigate(tester, 2);

    expect(_textInViewport(tester, '问题 2'), isTrue,
        reason: '热跳同样必须落到目标');
    expect(hot.length, lessThanOrEqualTo(cold.length),
        reason: '热缓存不应比冷跳更慢（冷 ${cold.length} 步 / 热 ${hot.length} 步）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实分页：10 轮 × ~250 条目（真机形状），中段目标穿长回复', (tester) async {
    final events = _denseTurnEvents(turns: 10, toolsPerTurn: 250);
    final backend = _PagedBackend(events: events, outlineTurns: 10);
    await _pumpChat(tester, backend: backend);
    await _leaveBottom(tester);

    await _navigate(tester, 5);

    expect(_textInViewport(tester, '问题 5'), isTrue,
        reason: '真机形状（轮少条目多）的中段目标也要进入视口');
    expect(tester.takeException(), isNull);
  });
}
