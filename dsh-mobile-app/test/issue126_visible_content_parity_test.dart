// ADR 0035 / issue #126：可见内容对齐与高度模型的最小回归。
//
// 覆盖：短内容顶对齐（无底部占位）、长用户消息按需详情、仅图片的 assistant 不丢。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/image_gallery.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _Backend {
  _Backend({required this.events, this.detail});

  final List<Map<String, dynamic>> events;
  final Map<String, dynamic>? detail;
  int detailRequests = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue126.test'
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
    if (path == '/m/api/history') {
      return _json({'ok': true, 'events': events, 'hasMore': false});
    }
    if (path == '/m/api/event-detail') {
      detailRequests++;
      final event = detail;
      if (event == null) {
        return _json({'ok': false, 'error': 'event-not-found'});
      }
      return _json({'ok': true, 'event': event});
    }
    if (path == '/m/api/attachment') {
      return http.Response.bytes(
        _tinyPng,
        200,
        headers: {'content-type': 'image/png'},
      );
    }
    if (path == '/m/api/queue') return _json({'ok': true, 'rows': <Object>[]});
    if (path == '/m/api/todos') return _json({'ok': true, 'todos': <Object>[]});
    if (path == '/m/api/session-config') {
      return _json({'ok': true, 'config': <String, dynamic>{}});
    }
    return _json({'ok': true});
  }

  http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<AppStore> _pump(WidgetTester tester, _Backend backend) async {
  final store = AppStore()
    ..sessionId = 'session-126'
    ..sessions = [
      Session(id: 'session-126', title: 'S', cwd: null, createdAt: 1),
    ];
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey('issue126-${backend.hashCode}'),
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
  testWidgets('短内容顶对齐：第一行贴近消息视口顶部，不被推到下方', (tester) async {
    final backend = _Backend(
      events: [
        {
          'seq': 1,
          'type': 'turn/start',
          'data': {'turn': 1},
          'time': 1000,
        },
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': '短问题', 'sourceKind': 'user'},
          'time': 1100,
        },
        {
          'seq': 3,
          'type': 'assistant/message',
          'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '短回答'},
          'time': 1200,
        },
        {
          'seq': 4,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'completed'},
          },
          'time': 1300,
        },
      ],
    );
    await _pump(tester, backend);
    final scroll = tester.getRect(find.byType(CustomScrollView));
    final user = tester.getRect(find.text('短问题'));
    expect(
      user.top - scroll.top,
      lessThan(60),
      reason: 'ADR 0035：短内容顶对齐，不能再被底部占位推下去',
    );
  });

  testWidgets('长用户消息：查看全文按需加载，正文完整可达', (tester) async {
    final head = 'H' * 2000;
    final full = '$head\nEND-OF-USER-MESSAGE';
    final backend = _Backend(
      events: [
        {
          'seq': 1,
          'type': 'turn/start',
          'data': {'turn': 1},
          'time': 1000,
        },
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': head, 'sourceKind': 'user'},
          'detail': {'available': true, 'seq': 2, 'textChars': full.length},
          'time': 1100,
        },
        {
          'seq': 3,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'completed'},
          },
          'time': 1300,
        },
      ],
      detail: {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': full, 'sourceKind': 'user'},
      },
    );
    await _pump(tester, backend);
    final button = find.text('查看全文');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 250));
    expect(backend.detailRequests, 1);
    expect(
      find.textContaining('END-OF-USER-MESSAGE'),
      findsOneWidget,
      reason: '详情加载后完整用户正文必须可达',
    );
  });

  testWidgets('仅图片的 assistant 消息不丢：图库入口仍渲染', (tester) async {
    final backend = _Backend(
      events: [
        {
          'seq': 1,
          'type': 'turn/start',
          'data': {'turn': 1},
          'time': 1000,
        },
        {
          'seq': 2,
          'type': 'assistant/message',
          'data': {
            'turn': 1,
            'step': 1,
            'messageId': 'a1',
            'text': '',
            'images': [
              {
                'attachmentId': 'sha256:img-1',
                'mediaType': 'image/png',
                'width': 10,
                'height': 10,
                'name': 'only.png',
              },
            ],
          },
          'time': 1100,
        },
        {
          'seq': 3,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'completed'},
          },
          'time': 1300,
        },
      ],
    );
    await _pump(tester, backend);
    expect(
      find.byType(ImageGalleryGrid),
      findsOneWidget,
      reason: '图片也算 reply content，不能整条消息跳过',
    );
  });
}
