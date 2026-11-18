// issue #53：轮末两卡在对话页的挂载与降级（ChatScreen 集成）。
//
// 固定：两卡默认收起、顺序在最终回答与轮次页脚之间、无文件不占位、无能力位（旧插件）
// 不渲染；改动卡懒加载失败静默重试 1 次后隐藏；行内链接打开同一预览页。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/screens/turn_file_preview_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/widgets/turn_tail_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TailBackend {
  _TailBackend({this.changed = false, this.summaryStatus = 200});

  final bool presented = true;
  final bool changed;
  final int summaryStatus;
  final String answerText = '已完成，见 `src/a.ts`';

  final List<String> paths = [];
  int summaryRequests = 0;
  bool includePresented = true;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://tail-chat.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
      unknownEvents: true,
      callCorrelation: true,
    )
    ..turnTailCapabilities = TurnTailCapabilities(
      version: 1,
      presented: presented,
      changed: changed,
      changesDiff: changed,
    );

  Future<http.Response> _handle(http.Request request) async {
    paths.add('${request.url.path}?${request.url.query}');
    if (request.url.path == '/m/api/history') {
      final events = <Map<String, dynamic>>[
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': '帮我做个文件', 'sourceKind': 'user'},
        },
        {
          'seq': 3,
          'type': 'assistant/message',
          'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': answerText},
        },
        if (includePresented)
          {
            'seq': 4,
            'type': 'deliverables/presented',
            'data': {
              'turn': 1,
              'callId': 'call-present',
              'files': [
                {'name': 'a.ts', 'display': 'src/a.ts', 'description': '最终交付'},
              ],
            },
          },
        {'seq': 5, 'type': 'workspace/changes', 'data': {'turn': 1}},
        {
          'seq': 6,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'completed'},
            'tail': {'changes': changed, 'presented': presented},
          },
        },
      ];
      return _json({
        'ok': true,
        'events': events,
        'hasMore': false,
        'turnTails': {
          '1': {'changes': changed, 'presented': presented},
        },
      });
    }
    if (request.url.path == '/m/api/changes/summary') {
      summaryRequests += 1;
      if (summaryStatus != 200) {
        return _json({'error': 'sessions-unavailable'}, summaryStatus);
      }
      return _json({
        'ok': true,
        'state': 'available',
        'turn': 1,
        'files': [
          {'seq': 5, 'index': 0, 'display': 'src/a.ts', 'name': 'a.ts', 'added': 7, 'deleted': 2},
        ],
        'total': 1,
        'added': 7,
        'deleted': 2,
        'truncated': false,
      });
    }
    if (request.url.path == '/m/api/turn-file') {
      return http.Response.bytes(
        utf8.encode('PARSED-FILE-CONTENT\n'),
        200,
        headers: {'content-type': 'text/plain'},
      );
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

  static http.Response _json(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

Future<void> _pumpChat(
  WidgetTester tester,
  AppStore store,
  _TailBackend backend,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: const ValueKey('tail-chat'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('交付卡挂在回答与页脚之间，展示 name/说明，旧 workspace/changes 不出现', (tester) async {
    final backend = _TailBackend();
    final store = AppStore()..sessionId = 'session-tail';
    await _pumpChat(tester, store, backend);

    expect(find.byKey(TurnTailCardKeys.deliveredCard), findsOneWidget);
    expect(find.text('交付文件 1 个'), findsOneWidget);
    expect(find.text('a.ts'), findsOneWidget);
    expect(find.text('最终交付'), findsOneWidget);
    expect(
      find.textContaining('workspace/changes'),
      findsNothing,
      reason: '裸事件类型名不得出现在普通模式',
    );
    // 顺序：回答 → 交付卡 → 轮次页脚（纵向位置）。
    final cardY = tester.getTopLeft(find.byKey(TurnTailCardKeys.deliveredCard)).dy;
    final footerY = tester.getTopLeft(find.text('已完成')).dy;
    expect(cardY, lessThan(footerY), reason: '两卡必须在轮次页脚之前');
  });

  testWidgets('旧插件（无 turnTail 能力位）不渲染两卡', (tester) async {
    final backend = _TailBackend();
    backend.api.turnTailCapabilities = const TurnTailCapabilities();
    final store = AppStore()..sessionId = 'session-tail';
    await _pumpChat(tester, store, backend);

    expect(find.byKey(TurnTailCardKeys.deliveredCard), findsNothing);
    expect(find.byKey(TurnTailCardKeys.changedCard), findsNothing);
    expect(find.text('交付文件 1 个'), findsNothing);
  });

  testWidgets('行内链接打开同一预览页（坐标取数）', (tester) async {
    final backend = _TailBackend();
    final store = AppStore()..sessionId = 'session-tail';
    await _pumpChat(tester, store, backend);

    await tester.tap(find.text('src/a.ts'));
    await tester.pumpAndSettle();
    expect(find.byType(TurnFilePreviewScreen), findsOneWidget);
    expect(backend.paths.any((path) => path.startsWith('/m/api/turn-file')), isTrue);
    expect(find.textContaining('PARSED-FILE-CONTENT'), findsWidgets);
  });

  testWidgets('改动卡按 tail.changes 懒加载摘要并显示统计', (tester) async {
    final backend = _TailBackend(changed: true);
    final store = AppStore()..sessionId = 'session-tail';
    await _pumpChat(tester, store, backend);

    expect(backend.summaryRequests, 1, reason: '卡片进入渲染时拉一次 summary');
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);
    expect(find.text('本轮改动 1 个文件'), findsOneWidget);
    expect(find.text('+7'), findsOneWidget);
    expect(find.text('−2'), findsOneWidget);
    expect(find.byKey(TurnTailCardKeys.changedRow(0)), findsOneWidget);
  });

  testWidgets('改动摘要失败静默重试 1 次后整卡不显示', (tester) async {
    final backend = _TailBackend(changed: true, summaryStatus: 500);
    final store = AppStore()..sessionId = 'session-tail';
    await _pumpChat(tester, store, backend);
    // 静默重试有 400ms 退避：显式推进定时器，再等 UI 稳定。
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(backend.summaryRequests, 2, reason: '失败静默重试 1 次');
    expect(find.byKey(TurnTailCardKeys.changedCard), findsNothing);
  });
}
