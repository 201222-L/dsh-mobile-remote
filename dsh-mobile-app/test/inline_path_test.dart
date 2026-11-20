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

  testWidgets('issue #88：绝对路径未精确命中记录时先确认，不误开同 basename 的记录', (tester) async {
    final fileRequests = <String>[];
    final turnFileRequests = <String>[];
    final api = Api(
      client: MockClient((request) async {
        if (request.url.path == '/m/api/history') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'hasMore': false,
              'turnTails': <String, dynamic>{},
              'events': [
                {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
                {
                  'seq': 2,
                  'type': 'user/message',
                  'data': {'messageId': 'u1', 'text': '看一下报告', 'sourceKind': 'user'},
                  'time': 1100,
                },
                {
                  'seq': 3,
                  'type': 'assistant/message',
                  'data': {
                    'turn': 1,
                    'step': 1,
                    'messageId': 'a1',
                    'text': '结果见 `/tmp/B/report.pdf`',
                  },
                  'time': 1200,
                },
                {
                  'seq': 4,
                  'type': 'deliverables/presented',
                  'data': {
                    'turn': 1,
                    'files': [
                      {'id': 'id-a', 'name': 'report.pdf', 'display': 'report.pdf'},
                    ],
                  },
                  'time': 1300,
                },
                {
                  'seq': 5,
                  'type': 'turn/end',
                  'data': {'turn': 1, 'reason': {'kind': 'completed'}},
                  'time': 1400,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/m/api/turn-file') {
          turnFileRequests.add(request.url.toString());
          return http.Response.bytes(utf8.encode('record A'), 200);
        }
        if (request.url.path == '/m/api/files') {
          fileRequests.add(request.url.queryParameters['path'] ?? '');
          return http.Response.bytes(
            utf8.encode('file B content'),
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
      ..baseUrl = 'http://inline88.test'
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
    final store = AppStore()..sessionId = 'session-inline88';
    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        store: store,
        apiClient: api,
        onTitleChanged: () {},
      ),
    ));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.text('/tmp/B/report.pdf'), findsOneWidget);
    await tester.tap(find.text('/tmp/B/report.pdf'));
    await tester.pumpAndSettle();

    // 必须走确认 sheet：不直接按记录 A 的 turn-file 坐标打开。
    expect(find.text('打开文件预览'), findsOneWidget);
    expect(turnFileRequests, isEmpty, reason: '绝对路径未精确命中时不得打开同 basename 的记录');
    expect(fileRequests, isEmpty, reason: '确认前不读取文件');

    await tester.tap(find.widgetWithText(FilledButton, '打开预览'));
    await tester.pumpAndSettle();
    expect(turnFileRequests, isEmpty);
    expect(fileRequests, ['/tmp/B/report.pdf'], reason: '确认后按用户点击的绝对路径读取');
    expect(find.textContaining('file B content'), findsOneWidget);
  });
}
