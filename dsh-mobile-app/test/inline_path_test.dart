// issue #83：正文行内绝对路径识别与按路径预览。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/inline_path.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/screens/turn_file_preview_screen.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('looksLikeInlineFilePath', () {
    test('识别 POSIX / Windows 绝对路径', () {
      expect(looksLikeInlineFilePath('/tmp/upstream-pr-a-cn.md'), isTrue);
      expect(looksLikeInlineFilePath('/home/mark/proj/a.png'), isTrue);
      expect(looksLikeInlineFilePath(r'C:\Users\me\a.txt'), isTrue);
      expect(looksLikeInlineFilePath('D:/work/a.md'), isTrue);
    });

    test('相对路径/URL/home/~ 缩写/目录/空路径不识别', () {
      for (final code in [
        'README.md',
        './a.md',
        '../a.md',
        'https://example.com/a.md',
        'file:///tmp/a.md',
        '~/a.md',
        '~',
        '/tmp/',
        '/',
        '/tmp/.',
        '/tmp/..',
        'C:\\',
        '',
        '/tmp/a b.md',
        '/tmp/a\nb.md',
      ]) {
        expect(looksLikeInlineFilePath(code), isFalse, reason: code);
      }
    });

    test('basename 提取', () {
      expect(inlinePathBasename('/tmp/a.md'), 'a.md');
      expect(inlinePathBasename(r'C:\Users\me\a.txt'), 'a.txt');
    });
  });

  testWidgets('按绝对路径预览：只请求 /api/files?path= 并渲染文本', (tester) async {
    final requests = <Uri>[];
    final api = Api(
      client: MockClient((request) async {
        requests.add(request.url);
        return http.Response.bytes(
          utf8.encode('hello from /tmp\nsecond line'),
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        );
      }),
    )..baseUrl = 'http://files.test'
     ..path = '/m'
     ..token = '';

    await tester.pumpWidget(MaterialApp(
      home: TurnFilePreviewScreen.path(
        api: api,
        path: '/tmp/upstream-pr-a-cn.md',
        display: '/tmp/upstream-pr-a-cn.md',
        name: 'upstream-pr-a-cn.md',
      ),
    ));
    await tester.pumpAndSettle();

    expect(requests, hasLength(1), reason: '只按路径读取一次');
    expect(requests.single.path, '/m/api/files');
    expect(requests.single.queryParameters['path'], '/tmp/upstream-pr-a-cn.md');
    expect(find.textContaining('hello from /tmp'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });


  testWidgets('对话行内绝对路径：取消不读取，确认后打开预览', (tester) async {
    final fileRequests = <String>[];
    final api = Api(
      client: MockClient((request) async {
        if (request.url.path == '/m/api/history') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'events': [
                {
                  'seq': 1,
                  'type': 'user/message',
                  'data': {'messageId': 'u1', 'text': '写个文件', 'sourceKind': 'user'},
                  'time': 1000,
                },
                {
                  'seq': 2,
                  'type': 'assistant/message',
                  'data': {
                    'messageId': 'a1',
                    'text': '已写入临时文件：`/tmp/upstream-pr-a-cn.md`',
                  },
                  'time': 1100,
                },
              ],
              'hasMore': false,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/m/api/files') {
          fileRequests.add(request.url.queryParameters['path'] ?? '');
          return http.Response.bytes(
            utf8.encode('hello from /tmp'),
            200,
            headers: {'content-type': 'text/plain; charset=utf-8'},
          );
        }
        return http.Response(
          jsonEncode({'ok': true, 'rows': <Object>[], 'todos': <Object>[], 'config': <String, dynamic>{}}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    )
      ..baseUrl = 'http://inline.test'
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
    final store = AppStore()..sessionId = 'session-inline';
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        store: store,
        apiClient: api,
        onTitleChanged: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('/tmp/upstream-pr-a-cn.md'), findsOneWidget);
    await tester.tap(find.text('/tmp/upstream-pr-a-cn.md'));
    await tester.pumpAndSettle();
    expect(find.text('打开文件预览'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(fileRequests, isEmpty, reason: '取消不得读取文件');

    await tester.tap(find.text('/tmp/upstream-pr-a-cn.md'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '打开预览'));
    await tester.pumpAndSettle();
    expect(fileRequests, ['/tmp/upstream-pr-a-cn.md']);
    expect(find.textContaining('hello from /tmp'), findsOneWidget);
  });
}
