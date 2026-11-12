// issue #94/#95 生产形状：ChatScreen 助手 Markdown 本地图 → Api.workspaceImage
// （sessionId/path/token）→ LRU → md ResizeImage；>8MiB 客户端拒绝；501 明确占位。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAF9Z2ZkAAAAASUVORK5CYII=',
);

class _Backend {
  _Backend({required this.imageStatus, this.bytes, this.assistantText = '说明\n\n![截图](pics/a.png)'});
  final int imageStatus;
  final Uint8List? bytes;
  final String assistantText;
  final List<Uri> imageRequests = [];

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://host.test'
    ..path = '/m'
    ..token = 'tkn';

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/history') {
      body = {
        'ok': true,
        'events': [
          {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
          {
            'seq': 2,
            'type': 'user/message',
            'data': {'messageId': 'u1', 'text': '看图', 'sourceKind': 'user'},
          },
          {
            'seq': 3,
            'type': 'assistant/message',
            'data': {
              'turn': 1,
              'messageId': 'a1',
              'text': assistantText,
            },
          },
        ],
      };
    } else if (path == '/m/api/workspace-image') {
      imageRequests.add(request.url);
      if (imageStatus != 200) {
        return http.Response(
          jsonEncode({'ok': false, 'error': 'image-too-large'}),
          imageStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(
        bytes ?? _png,
        200,
        headers: {'content-type': 'image/png'},
      );
    } else if (path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else {
      body = {'ok': true};
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});
  }
}

Future<void> _pump(WidgetTester tester, _Backend backend) async {
  L10n.lang = 'en';
  final store = AppStore()
    ..sessionId = 'session-img'
    ..sessions = [Session(id: 'session-img', title: 'S', cwd: null, createdAt: 1)];
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      store: store,
      apiClient: backend.api,
      onTitleChanged: () {},
    ),
  ));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('正常本地图：带 session/path 请求，渲染 ResizeImage', (tester) async {
    final backend = _Backend(imageStatus: 200);
    await _pump(tester, backend);
    expect(backend.imageRequests, hasLength(1));
    expect(backend.imageRequests.single.queryParameters['sessionId'], 'session-img');
    expect(backend.imageRequests.single.queryParameters['path'], 'pics/a.png');
    final image = find.byType(Image);
    expect(image, findsOneWidget);
    expect(tester.widget<Image>(image).image, isA<ResizeImage>());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('>8MiB 响应：客户端拒绝并显示 alt+原因', (tester) async {
    final backend = _Backend(
      imageStatus: 200,
      bytes: Uint8List(8 * 1024 * 1024 + 1),
    );
    await _pump(tester, backend);
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const Key('markdown-image-placeholder')), findsOneWidget);
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('Image too large'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('501 安全校验不可用：明确占位，不回退路径读取', (tester) async {
    final backend = _Backend(imageStatus: 501);
    await _pump(tester, backend);
    expect(find.byKey(const Key('markdown-image-placeholder')), findsOneWidget);
    expect(find.text('截图'), findsOneWidget);
    expect(find.textContaining('cannot verify images safely'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('同路径多图只发一次 HTTP（LRU/in-flight 去重）', (tester) async {
    final backend = _Backend(
      imageStatus: 200,
      assistantText: '双图\n\n![一](pics/a.png)\n\n![二](pics/a.png)',
    );
    await _pump(tester, backend);
    expect(backend.imageRequests, hasLength(1), reason: '同 session|path 只请求一次');
    expect(find.byType(Image), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

}
