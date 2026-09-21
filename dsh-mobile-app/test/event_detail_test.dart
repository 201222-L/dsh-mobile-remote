import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:flutter_test/flutter_test.dart';

Future<HttpServer> _serverFor(Map<String, dynamic> body, {int status = 200}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  });
  return server;
}

Api _client(HttpServer server) => Api()
  ..baseUrl = 'http://${server.address.address}:${server.port}'
  ..path = '/m'
  ..token = '';

void main() {
  test('event detail preserves current-surface degradation metadata', () async {
    final server = await _serverFor({
      'ok': true,
      'event': {
        'seq': 8,
        'type': 'tool/result',
        'data': {'text': 'recovered'},
      },
      'degraded': true,
      'detailMode': 'current-surface',
    });
    addTearDown(server.close);

    final detail = await _client(server).eventDetail('seeded', 8);

    expect(detail.event['data']['text'], 'recovered');
    expect(detail.degraded, isTrue);
    expect(detail.detailMode, 'current-surface');
  });

  test('event detail exposes stable error code without inventing raw diagnostics', () async {
    final server = await _serverFor({
      'error': 'event-read-failed',
      'detail': '事件详情读取失败',
    }, status: 500);
    addTearDown(server.close);

    await expectLater(
      _client(server).eventDetail('broken', 9),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 'event-read-failed')
            .having((error) => error.message, 'message', '事件详情读取失败'),
      ),
    );
  });
}
