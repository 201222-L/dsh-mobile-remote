// issue #60 R04：真实 `limit=50` 分页下，缺 turn/start 的最新长轮次不得整轮消失。
//
// 复现：初次历史只取最近 50 条；工具很多的最新已完成轮，窗口含工具/回答/end 却没有
// start。修复前 tracker 整轮丢弃 → 展示模式失效、页脚与 M2 两卡都不可见。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/turn_tail_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _PagedBackend {
  _PagedBackend() {
    // 115 条事件：turn/start(1) → user(2) → 55 组 tool/call+result(3..112) →
    // assistant(113) → presented(114) → turn/end(115)。初次 limit=50 缺 start。
    events.add({
      'seq': 1,
      'type': 'turn/start',
      'time': 1000,
      'data': {'turn': 1},
    });
    events.add({
      'seq': 2,
      'type': 'user/message',
      'time': 1100,
      'data': {'messageId': 'u1', 'text': '跑很多工具', 'sourceKind': 'user'},
    });
    var seq = 3;
    for (var i = 0; i < 55; i += 1) {
      events.add({
        'seq': seq++,
        'type': 'tool/call',
        'time': 1200 + i * 10,
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'c$i',
          'name': 'bash',
          'arguments': '{"command":"echo x"}',
        },
      });
      events.add({
        'seq': seq++,
        'type': 'tool/result',
        'time': 1201 + i * 10,
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'c$i',
          'name': 'bash',
          'text': 'x',
          'isError': false,
        },
      });
    }
    events.add({
      'seq': seq++,
      'type': 'assistant/message',
      'time': 9000,
      'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '全部完成'},
    });
    events.add({
      'seq': seq++,
      'type': 'deliverables/presented',
      'time': 9100,
      'data': {
        'turn': 1,
        'callId': 'call-present',
        'files': [
          {'name': 'report.md', 'display': 'report.md', 'description': '最终交付'},
        ],
      },
    });
    events.add({
      'seq': seq++,
      'type': 'turn/end',
      'time': 9200,
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
        'tail': {'changes': false, 'presented': true},
      },
    });
  }

  final List<Map<String, dynamic>> events = [];
  int? lastLimit;
  int historyRequests = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://r04.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
    )
    ..turnTailCapabilities = const TurnTailCapabilities(
      version: 1,
      presented: true,
      changed: false,
      changesDiff: false,
    );

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      historyRequests += 1;
      final after = request.url.queryParameters['after'];
      if (after != null) {
        return _json({'ok': true, 'events': <Object>[], 'hasMore': false});
      }
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 50;
      lastLimit = limit;
      final start = events.length > limit ? events.length - limit : 0;
      final page = events.sublist(start);
      return _json({
        'ok': true,
        'events': page,
        'hasMore': start > 0,
        'turnTails': {
          '1': {'changes': false, 'presented': true},
        },
      });
    }
    if (request.url.path == '/m/api/notifications') {
      return _json({'ok': true, 'items': <Object>[]});
    }
    if (request.url.path == '/m/api/queue') {
      return _json({'ok': true, 'rows': <Object>[]});
    }
    if (request.url.path == '/m/api/todos') {
      return _json({'ok': true, 'todos': <Object>[]});
    }
    return _json({'ok': true});
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  testWidgets('真实 limit=50 初次加载：缺 turn/start 的最新轮仍有页脚与交付卡', (tester) async {
    final backend = _PagedBackend();
    final store = AppStore()..sessionId = 'session-r04';
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          store: store,
          apiClient: backend.api,
          onTitleChanged: () {},
          autoFillFirstScreen: false,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(backend.lastLimit, 50, reason: '用例必须走真实 50 条分页，不能用 returnAll 绕过');
    expect(backend.historyRequests, greaterThanOrEqualTo(1));

    // 窗口里确实没有 turn/start（修复前 tracker 会因此整轮丢弃）。
    final headSeq = backend.events.length > 50
        ? backend.events[backend.events.length - 50]['seq'] as int
        : 0;
    expect(headSeq, greaterThan(1));

    // 页脚 + 交付卡必须出现（partial 轮次保留了轮次身份）。
    expect(find.text('已完成'), findsOneWidget);
    expect(find.byKey(TurnTailCardKeys.deliveredCard), findsOneWidget);
    expect(find.text('report.md'), findsOneWidget);
    // 缺 time 的起点 → 按既有规则不显示用时。
    expect(find.textContaining('用时'), findsNothing);
  });
}
