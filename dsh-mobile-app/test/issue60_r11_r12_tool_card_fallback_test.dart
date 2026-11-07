// issue #60 R11/R12：专用工具卡的失败原因可达性与无 diff 时的通用回退。

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

const _tools = [
  'edit',
  'write',
  'read_image',
];

class _Backend {
  _Backend({this.editFailure = false, this.imageFailure = false, this.truncatedWrite = false});

  final bool editFailure;
  final bool imageFailure;
  final bool truncatedWrite;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://r11.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
    )
    ..toolCardsCapabilities = const ToolCardsCapabilities(
      version: 1,
      tools: {'edit', 'write', 'read_image'},
    );

  List<Map<String, dynamic>> get _events {
    final events = <Map<String, dynamic>>[
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '改文件', 'sourceKind': 'user'},
      },
    ];
    var seq = 3;
    if (editFailure) {
      events.add({
        'seq': seq++,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-edit',
          'name': 'edit',
          'arguments': '{"file_path":"src/a.ts","old_string":"a","new_string":"b"}',
          'summary': {
            'kind': 'file',
            'tool': 'edit',
            'filePath': 'src/a.ts',
            'sizeKb': 1,
            'added': 1,
            'deleted': 1,
            'diff': '--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,1 +1,1 @@\n-a\n+b\n',
          },
        },
      });
      events.add({
        'seq': seq++,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-edit',
          'name': 'edit',
          'isError': true,
          'text': 'old_string not found in src/a.ts',
        },
      });
    }
    if (imageFailure) {
      events.add({
        'seq': seq++,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-image',
          'name': 'read_image',
          'arguments': '{"file_path":"assets/missing.png"}',
          'summary': {
            'kind': 'image',
            'tool': 'read_image',
            'filePath': 'assets/missing.png',
          },
        },
      });
      events.add({
        'seq': seq++,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-image',
          'name': 'read_image',
          'isError': true,
          'text': 'cannot read image: ENOENT assets/missing.png',
        },
      });
    }
    if (truncatedWrite) {
      events.add({
        'seq': seq++,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-write',
          'name': 'write',
          'arguments': '{"file_path":"src/big.ts","content":"FIRST-LINE-CONTENT\\nmore"}',
          'summary': {
            'kind': 'file',
            'tool': 'write',
            'filePath': 'src/big.ts',
            'sizeKb': 9,
            'diffTruncated': true,
          },
        },
      });
      events.add({
        'seq': seq++,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-write',
          'name': 'write',
          'text': 'wrote src/big.ts',
          'isError': false,
        },
      });
    }
    events.add({
      'seq': seq++,
      'type': 'turn/end',
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
    });
    return events;
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      return _json({'ok': true, 'events': _events, 'hasMore': false});
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

Future<void> _pumpChat(WidgetTester tester, _Backend backend) async {
  final store = AppStore()
    ..sessionId = 'session-r11'
    ..stepDisplayMode = WorkStepDisplayMode.expanded;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Finder _card(String callId, int seq) =>
    find.byKey(ValueKey<String>('tool:$callId:$seq'));

void main() {
  testWidgets('R11：edit 失败时专用卡保留真实 toolResult 原因', (tester) async {
    await _pumpChat(tester, _Backend(editFailure: true));
    await tester.tap(_card('call-edit', 3));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('old_string not found'),
      findsOneWidget,
      reason: '失败原因必须可达，不能被"尝试的 diff"遮住',
    );
  });

  testWidgets('R11：read_image 失败且无图片时显示真实错误', (tester) async {
    await _pumpChat(tester, _Backend(imageFailure: true));
    await tester.tap(_card('call-image', 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot read image'), findsOneWidget);
  });
}
