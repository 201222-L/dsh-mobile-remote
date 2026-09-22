// HistoryPage 解析单测（v3.1.5 休眠会话降级透传）：
// 验证 degraded/historyMode 能从 JSON 进入 HistoryPage；旧服务端不返回这些字段时保持兼容。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/api.dart';

const _eventJson = {
  'seq': 100,
  'type': 'assistant/message',
  'data': {
    'message': {
      'id': 'assistant-100',
      'content': [
        {'type': 'text', 'text': 'surface tail'},
      ],
    },
  },
};

Future<HttpServer> _spawnServer(Map<String, dynamic> body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) {
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'ok': true,
        'after': 100,
        ...body,
      }))
      ..close();
  });
  return server;
}

Api _apiFor(HttpServer server) =>
    Api()
      ..baseUrl = 'http://127.0.0.1:${server.port}'
      ..token = '';

void main() {
  test('historyPage 解析 degraded=true + historyMode=current-surface，事件可达', () async {
    final server = await _spawnServer({
      'degraded': true,
      'historyMode': 'current-surface',
      'events': [_eventJson],
    });
    try {
      final page = await _apiFor(server).historyPage('s');
      expect(page.degraded, isTrue);
      expect(page.historyMode, 'current-surface');
      expect(page.events, hasLength(1));
      expect(page.events.single.seq, 100);
      expect(page.events.single.type, 'assistant/message');
    } finally {
      await server.close(force: true);
    }
  });

  test('旧服务端不返回 degraded/historyMode 时保持兼容（degraded=false）', () async {
    final server = await _spawnServer({'events': [_eventJson]});
    try {
      final page = await _apiFor(server).historyPage('s');
      expect(page.degraded, isFalse);
      expect(page.historyMode, isNull);
      expect(page.events, hasLength(1));
    } finally {
      await server.close(force: true);
    }
  });

  test('无事件时 events 为空数组且不抛错', () async {
    final server = await _spawnServer({'degraded': true, 'events': []});
    try {
      final page = await _apiFor(server).historyPage('s');
      expect(page.degraded, isTrue);
      expect(page.events, isEmpty);
    } finally {
      await server.close(force: true);
    }
  });
}