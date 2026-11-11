// issue #53：按坐标预览页（文本 / 图片 / 二进制 / 失败重试）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/turn_file_preview_screen.dart';
import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _coordinate = TurnFileCoordinate(
  sessionId: 's1',
  kind: TurnFileKind.presented,
  seq: 3,
  index: 0,
);

Api _api(MockClient client) => Api(client: client)
  ..baseUrl = 'http://preview.test'
  ..path = '/m'
  ..token = '';

Widget _wrap(Api api, {required String name, String display = 'src/a.txt'}) =>
    MaterialApp(
      home: TurnFilePreviewScreen(
        api: api,
        coordinate: _coordinate,
        display: display,
        name: name,
      ),
    );

// 1x1 透明 PNG（合法可解码，避免 widget 测试里 Image.memory 抛解码错误）。
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('文本文件：按坐标取字节并渲染 GitFileViewer 内容', (tester) async {
    late http.Request captured;
    final api = _api(
      MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode('const a = 1;\nconst b = 2;\n'),
          200,
          headers: {'content-type': 'text/plain'},
        );
      }),
    );
    await tester.pumpWidget(_wrap(api, name: 'a.txt'));
    await tester.pumpAndSettle();
    expect(captured.url.path, '/m/api/turn-file');
    expect(captured.url.queryParameters['kind'], 'presented');
    expect(captured.url.queryParameters['seq'], '3');
    expect(find.byKey(const Key('turn-file-preview')), findsOneWidget);
    expect(find.textContaining('const a = 1;'), findsWidgets);
  });

  testWidgets('图片文件：Image.memory 预览，不按文本截断', (tester) async {
    final api = _api(
      MockClient((request) async {
        return http.Response.bytes(
          _pngBytes,
          200,
          headers: {'content-type': 'image/png', 'content-length': '${_pngBytes.length}'},
        );
      }),
    );
    await tester.pumpWidget(
      _wrap(api, name: 'p.png', display: 'assets/p.png'),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('turn-file-preview-image')), findsOneWidget);
  });

  testWidgets('二进制文件：给出不可预览提示（不渲染乱码）', (tester) async {
    final api = _api(
      MockClient((request) async {
        return http.Response.bytes(
          Uint8List.fromList([0, 1, 2, 3, 0, 255]),
          200,
          headers: {'content-type': 'application/octet-stream'},
        );
      }),
    );
    await tester.pumpWidget(_wrap(api, name: 'bin.dat', display: 'bin.dat'));
    await tester.pumpAndSettle();
    expect(find.textContaining('二进制'), findsWidgets);
  });

  testWidgets('读取失败给出明确错误，重试成功后渲染内容', (tester) async {
    var calls = 0;
    final api = _api(
      MockClient((request) async {
        calls += 1;
        if (calls == 1) {
          return http.Response(
            jsonEncode({'error': 'file-not-found'}),
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(utf8.encode('recovered\n'), 200);
      }),
    );
    await tester.pumpWidget(_wrap(api, name: 'a.txt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法读取文件'), findsWidgets);
    await tester.tap(find.byKey(const Key('turn-file-preview-retry')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('recovered'), findsWidgets);
  });
}
