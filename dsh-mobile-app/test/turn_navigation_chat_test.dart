// issue #24：刻度轨在**真实对话页**里的集成测试（Seam 2 的后半）。
//
// `turn_navigator_rail_test.dart` 覆盖刻度轨自身的手势与呈现；本文件把真实的
// `ChatScreen` 接上假后端（复用 `chat_screen_test.dart` 的 MockClient 注入先例），
// 验证"什么时候出现"这一层：显隐由对话页的滚动位置与轮次数量共同决定，
// 且点按刻度会走通定位路径。
//
// 只断言用户可观察行为，不锁死内部实现。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/turn_navigator_rail.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 造一个"多轮 + 够长"的会话：每轮 = turn/start + 用户消息 + 助手长回复。
/// 内容必须超过视口，否则无法上翻、刻度轨也就没有显形条件。
List<Map<String, dynamic>> _turnsEvents({int turns = 6}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  for (var turn = 1; turn <= turns; turn++) {
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
        // 足够长，保证列表可滚动。
        'text': '第 $turn 轮的回答' * 40,
      },
    });
  }
  return events;
}

class _TurnBackend {
  _TurnBackend({this.turns = 6}) {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://turns.test'
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
  }

  final int turns;
  late final Api api;

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    if (request.url.path == '/m/api/history') {
      // 上翻（带 before）返回空页：本用例只关心已加载窗口内的定位。
      body = request.url.queryParameters.containsKey('before')
          ? {'ok': true, 'events': <Object>[], 'hasMore': false}
          : {
              'ok': true,
              'events': _turnsEvents(turns: turns),
              'hasMore': false,
            };
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

Future<void> _pumpChat(
  WidgetTester tester, {
  required _TurnBackend backend,
  required AppStore store,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      key: const ValueKey('turn-chat'),
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
}

/// 上翻：把消息流往下拖（内容向旧消息方向移动），离开底部。
Future<void> _scrollUp(WidgetTester tester, {double by = 600}) async {
  await tester.drag(find.byType(CustomScrollView), Offset(0, by));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('停留在最新时不渲染刻度轨（避免无谓的视觉噪声）', (tester) async {
    final backend = _TurnBackend();
    final store = AppStore()..sessionId = 'session-turns';
    await _pumpChat(tester, backend: backend, store: store);

    expect(find.byType(TurnNavigatorRail), findsNothing,
        reason: '初始位于底部，刻度轨不应出现');
  });

  testWidgets('上翻离开底部后刻度轨出现，且刻度数与已加载轮次一致', (tester) async {
    final backend = _TurnBackend(turns: 6);
    final store = AppStore()..sessionId = 'session-turns';
    await _pumpChat(tester, backend: backend, store: store);

    await _scrollUp(tester);

    expect(find.byType(TurnNavigatorRail), findsOneWidget,
        reason: '离开底部且轮次数 ≥2 → 显形');
    for (var turn = 1; turn <= 6; turn++) {
      expect(find.byKey(ValueKey<String>('turn-tick-$turn')), findsOneWidget,
          reason: '第 $turn 轮应有刻度');
    }
    expect(find.byKey(const ValueKey<String>('turn-tick-7')), findsNothing);
  });

  testWidgets('只有一轮时不渲染刻度轨（即使离开底部）', (tester) async {
    final backend = _TurnBackend(turns: 1);
    final store = AppStore()..sessionId = 'session-one-turn';
    await _pumpChat(tester, backend: backend, store: store);

    await _scrollUp(tester);

    expect(find.byType(TurnNavigatorRail), findsNothing,
        reason: '一轮没有导航价值');
  });

  testWidgets('点按刻度的定位路径可走通：目标轮最终进入视图且不抛异常', (tester) async {
    final backend = _TurnBackend(turns: 6);
    final store = AppStore()..sessionId = 'session-turns';
    await _pumpChat(tester, backend: backend, store: store);

    await _scrollUp(tester);
    expect(find.byType(TurnNavigatorRail), findsOneWidget);

    // 点最靠上的一轮（离当前视口最远），走迭代定位。
    await tester.tap(
      find.byKey(const ValueKey<String>('turn-tick-1')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('第 1 轮的问题'), findsOneWidget,
        reason: '定位后该轮应进入已构建范围');
  });

  testWidgets('刻度轨不是滚动死区：沿轨扫掠出预览并落到所指轮次', (tester) async {
    final backend = _TurnBackend(turns: 6);
    final store = AppStore()..sessionId = 'session-turns';
    await _pumpChat(tester, backend: backend, store: store);

    await _scrollUp(tester, by: 300);
    expect(find.byType(TurnNavigatorRail), findsOneWidget);

    // 刻度轨用 opaque 命中（2px 的刻度条对拇指太小），因此它必须**消费**竖直拖动，
    // 否则右侧 28px 会变成一条什么都不做的死区。这里把它钉死为两条可观察结果：
    // 扫掠中浮出**具体那一轮**的预览；松手落在预览所指轮次，且目标真的进入视口。
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-2'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(TurnNavigatorRail),
        matching: find.text('第 2 轮的问题'),
      ),
      findsOneWidget,
      reason: '扫掠中必须浮出该轮的提示词预览（不是"没有异常就算过"）',
    );

    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-4'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final landed = find.text('第 4 轮的问题');
    expect(landed, findsOneWidget, reason: '松手后目标轮应已构建');
    expect(viewport.overlaps(tester.getRect(landed)), isTrue,
        reason: '落点是"目标与视口相交"，不只是已构建');
  });

  testWidgets('消息流本身仍可正常上翻（轨道之外的滚动不受影响）', (tester) async {
    final backend = _TurnBackend(turns: 6);
    final store = AppStore()..sessionId = 'session-turns';
    await _pumpChat(tester, backend: backend, store: store);

    final listScrollable = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    double offset() =>
        tester.state<ScrollableState>(listScrollable).position.pixels;
    final before = offset();

    await _scrollUp(tester, by: 300);

    expect(offset(), lessThan(before), reason: '消息流照常滚动');
    expect(find.byType(TurnNavigatorRail), findsOneWidget);
  });
}
