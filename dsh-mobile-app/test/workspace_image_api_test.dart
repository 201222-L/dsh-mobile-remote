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

  test('issue #98：consent 申请与带 consentId 的读取（query/token）', () async {
    final seen = <http.Request>[];
    final api = Api(client: MockClient((request) async {
      seen.add(request);
      if (request.url.path.endsWith('/workspace-image/consent')) {
        return http.Response(
          jsonEncode({
            'ok': true,
            'consentId': 'c-1',
            'scope': 'session-directory',
            'expiresAt': '2026-11-13T15:00:00Z',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});
    }))
      ..baseUrl = 'http://host.test'
      ..path = '/m'
      ..token = 't';
    final issued = await api.createWorkspaceImageConsent(
      sessionId: 's 1',
      path: 'worktree/pics/a b.png',
      scope: 'session-directory',
    );
    expect(issued['consentId'], 'c-1');
    expect(seen.single.url.path, '/m/api/workspace-image/consent');
    expect(seen.single.headers['x-mobile-token'], 't');
    expect(jsonDecode(seen.single.body), {
      'sessionId': 's 1',
      'path': 'worktree/pics/a b.png',
      'scope': 'session-directory',
    });

    await api.workspaceImage('s 1', 'worktree/pics/a b.png', consentId: 'c-1');
    expect(seen.last.url.queryParameters, {
      'sessionId': 's 1',
      'path': 'worktree/pics/a b.png',
      'consentId': 'c-1',
    });
  });

  test('issue #98：consent-required / consent-invalid 保留 code 供 UI 分类', () async {
    for (final code in ['consent-required', 'consent-invalid']) {
      final api = Api(client: MockClient((request) async => http.Response(
            jsonEncode({'ok': false, 'error': code}),
            403,
            headers: {'content-type': 'application/json'},
          )))
        ..baseUrl = 'http://host.test'
        ..token = 't';
      await expectLater(
        api.workspaceImage('s', 'pics/a.png', consentId: 'c'),
        throwsA(isA<ApiException>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.code, 'code', code)),
      );
    }
  });

}
