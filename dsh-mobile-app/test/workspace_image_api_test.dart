// issue #94：Api.workspaceImage 真实请求路径（MockClient）——token/query/bytes/错误码。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile_app/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMBAF9Z2ZkAAAAASUVORK5CYII=',
);

void main() {
  test('GET /m/api/workspace-image：带 token/session/path，返回 bytes/content-type', () async {
    late http.Request seen;
    final client = MockClient((request) async {
      seen = request;
      return http.Response.bytes(
        _png,
        200,
        headers: {'content-type': 'image/png', 'etag': '"abc"'},
      );
    });
    final api = Api(client: client)
      ..baseUrl = 'http://host.test'
      ..path = '/m'
      ..token = 'secret-token'
      ..appVersion = '1.2.3';
    final data = await api.workspaceImage('session/1', 'pics/a b.png');
    expect(seen.method, 'GET');
    expect(seen.url.path, '/m/api/workspace-image');
    expect(seen.url.queryParameters['sessionId'], 'session/1');
    expect(seen.url.queryParameters['path'], 'pics/a b.png');
    expect(seen.headers['x-mobile-token'], 'secret-token');
    expect(seen.headers['x-mobile-app-version'], '1.2.3');
    expect(seen.headers['accept'], 'image/*');
    expect(data.bytes, _png);
    expect(data.contentType, 'image/png');
  });

  test('错误状态：抛 ApiException（status/code 可判别，供 alt+原因占位）', () async {
    Future<void> expectError(int status, String code) async {
      final api = Api(client: MockClient((request) async => http.Response(
            jsonEncode({'ok': false, 'error': code, 'detail': 'nope'}),
            status,
            headers: {'content-type': 'application/json'},
          )))
        ..baseUrl = 'http://host.test'
        ..token = 't';
      await expectLater(
        api.workspaceImage('s', 'x.png'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', status)
            .having((e) => e.code, 'code', code)),
      );
    }

    await expectError(404, 'image-not-found');
    await expectError(403, 'path-outside-workspace');
    await expectError(413, 'image-too-large');
    await expectError(415, 'unsupported-image-type');
  });
}
