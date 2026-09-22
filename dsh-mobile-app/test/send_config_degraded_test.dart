// configDegraded 透传单测（v3.1.5 休眠会话配置回退）：
// 服务端在 /send 响应上附带 configDegraded=true 时，Api.send / sendImages 必须把它透出——
// 否则 App 无处提示「该会话配置已回退默认」，用户会在不知情的情况下被换成默认模型/权限。
// 旧服务端不返回该字段时保持 false（向后兼容）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/api.dart';

Future<HttpServer> _spawnServer(Map<String, dynamic> body) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    await req.drain();
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'ok': true, ...body}))
      ..close();
  });
  return server;
}

Api _apiFor(HttpServer server) => Api()
  ..baseUrl = 'http://127.0.0.1:${server.port}'
  ..token = '';

void main() {
  test('send 透传 configDegraded=true（seeded 休眠会话配置回退默认）', () async {
    final server = await _spawnServer({'messageId': 'm1', 'configDegraded': true});
    try {
      final (mid, note, configDegraded) = await _apiFor(server).send('s', 'hi');
      expect(mid, 'm1');
      expect(note, isNull);
      expect(configDegraded, isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('旧服务端不返回 configDegraded 时为 false（向后兼容）', () async {
    final server = await _spawnServer({'messageId': 'm2'});
    try {
      final (mid, _, configDegraded) = await _apiFor(server).send('s', 'hi');
      expect(mid, 'm2');
      expect(configDegraded, isFalse);
    } finally {
      await server.close(force: true);
    }
  });

  test('sendImages 同样透传 configDegraded', () async {
    final server = await _spawnServer({'accepted': true, 'note': 'held-until-idle', 'configDegraded': true});
    try {
      final (accepted, note, configDegraded) = await _apiFor(server)
          .sendImages('s', 'hi', [
        {'mediaType': 'image/png', 'data': 'AAAA'},
      ]);
      expect(accepted, isTrue);
      expect(note, 'held-until-idle');
      expect(configDegraded, isTrue);
    } finally {
      await server.close(force: true);
    }
  });

  test('configDegraded 是脏值（非 true）时不误判为 true', () async {
    final server = await _spawnServer({'messageId': 'm3', 'configDegraded': 'yes'});
    try {
      final (_, _, configDegraded) = await _apiFor(server).send('s', 'hi');
      expect(configDegraded, isFalse);
    } finally {
      await server.close(force: true);
    }
  });
}
