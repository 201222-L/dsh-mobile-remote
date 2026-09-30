// 回归：会话文件浏览**不得**用新建的 Api 实例发请求。
//
// 真机症状（v3.1.5+37 实测）：打开「文件」后显示
//   「无法读取目录：Invalid argument(s): No host specified in URI /m/api/directories?path=...」
//
// 根因：`Api` 的 `baseUrl` 默认是空串，要由启动流程从 SharedPreferences 载入
// （api.dart 的 loadPrefs）。控制器原先写 `api ?? Api()`，于是绕开了全局已配置的
// 单例，`_uri()` 拼出 `/m/api/...` 这种没有 scheme/host 的 URL，dart:io 直接抛。
//
// 本文件用**真实 HttpServer**验证：把全局 api 单例指向它，然后**默认构造**控制器
// （不注入 apiClient）并 open()。只有控制器确实复用全局单例时，请求才带得上 host
// 并被这台服务器收到；若有人把实现改回 `Api()`，baseUrl 为空 → 请求抛
// 「No host specified in URI」→ 这些用例立刻变红。
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/session_files_controller.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 极简目录服务：记录收到的 path 查询参数，返回一个固定目录。
class _FakeHost {
  _FakeHost._(this.server);

  final HttpServer server;
  final List<String> listed = [];

  static Future<_FakeHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final self = _FakeHost._(server);
    server.listen((req) async {
      final path = req.uri.queryParameters['path'] ?? '';
      if (req.uri.path.endsWith('/api/directories')) {
        self.listed.add(path);
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'ok': true,
              'path': path,
              'dirs': ['src'],
              'files': ['README.md'],
            }),
          );
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    return self;
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认构造的控制器复用全局 api 单例（真机 bug 的回归）', () async {
    final host = await _FakeHost.start();
    addTearDown(host.stop);

    // 只配置全局单例——不注入任何 apiClient。
    api
      ..baseUrl = 'http://127.0.0.1:${host.server.port}'
      ..path = '/m'
      ..token = '';

    final store = AppStore()
      ..sessions = [Session(id: 's1', cwd: '/work', createdAt: 1)];
    final c = SessionFilesController(store: store, sessionId: 's1');

    await c.open();

    expect(
      c.stage,
      BrowseStage.listing,
      reason: '默认构造必须走全局 api；若新建 Api() 会因空 baseUrl 抛「No host specified in URI」',
    );
    expect(host.listed, ['/work'], reason: '请求必须真的落到配置过 host 的那台服务端');
    expect(c.errorReason, isNot(contains('No host')));
  });

  test('会话没有工作目录时在发请求前停下（不误报网络错）', () async {
    final host = await _FakeHost.start();
    addTearDown(host.stop);
    api
      ..baseUrl = 'http://127.0.0.1:${host.server.port}'
      ..path = '/m'
      ..token = '';

    final store = AppStore()
      ..sessions = [Session(id: 's1', cwd: null, createdAt: 1)];
    final c = SessionFilesController(store: store, sessionId: 's1');

    await c.open();

    expect(c.stage, BrowseStage.error);
    expect(c.errorReason, contains('工作目录'));
    expect(host.listed, isEmpty, reason: '没有可浏览的根就不该发请求');
    expect(c.errorReason, isNot(contains('No host')));
  });
}
