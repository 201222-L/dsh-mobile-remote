// issue #13 侧查（可复核的最小复现）：eventsRaw() 的"取消窗口"连接泄漏。
//
// 用法：把本文件复制到 dsh-mobile-app/test/ 下，然后
//   cd dsh-mobile-app; flutter test test/sse_cancel_window_test.dart
//
// 预期（当前 main 未修）：
//   对照用例通过（total=0）；
//   "取消窗口"用例失败：Expected 0, Actual 1；
//   "连续重建"用例失败：Expected 0, Actual 3。
// 应用两行修法后（api.dart eventsRaw 内加 `cancelled` 标记并在晚到响应分支判断）三条全绿。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/api.dart';

class FakeSse {
  FakeSse._(this.server);
  final HttpServer server;
  int responses = 0;
  final List<Timer> _timers = [];

  static Future<FakeSse> start({required Duration beforeRespond}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final self = FakeSse._(server);
    server.listen((req) async {
      self.responses++;
      await Future<void>.delayed(beforeRespond); // 慢响应窗口（真机：握手/Tailscale 隧道建立）
      final res = req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('text', 'event-stream')
        ..bufferOutput = false; // 必须！默认 true 时帧根本不上线
      res.done.catchError((_) {});
      void write(String s) {
        try {
          res.add(utf8.encode(s));
          res.flush().catchError((_) {});
        } catch (_) {}
      }

      write('data: {"type":"hello","capabilities":{}}\n\n');
      self._timers
          .add(Timer.periodic(const Duration(milliseconds: 250), (_) => write(': ping\n\n')));
    });
    return self;
  }

  int get openConnections => server.connectionsInfo().total;

  Future<void> stop() async {
    for (final t in _timers) {
      t.cancel();
    }
    await server.close(force: true);
  }
}

Api mkApi(FakeSse s) => Api()
  ..baseUrl = 'http://127.0.0.1:${s.server.port}'
  ..token = '';

void main() {
  test('对照：响应到达后取消（正常路径）→ 连接释放', () async {
    final s = await FakeSse.start(beforeRespond: Duration.zero);
    addTearDown(s.stop);
    final sub = mkApi(s).eventsRaw().listen((_) {}, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await sub.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    print('对照: responses=${s.responses} 残留连接=${s.openConnections}');
    expect(s.openConnections, 0, reason: '正常取消必须释放连接');
  });

  test('取消窗口：响应到达前取消（resume/switchBase/disposeBridge 的动作）', () async {
    final s = await FakeSse.start(beforeRespond: const Duration(milliseconds: 900));
    addTearDown(s.stop);
    final sub = mkApi(s).eventsRaw().listen((_) {}, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await sub.cancel(); // bodySub 仍为 null → onCancel 什么也没做
    await Future<void>.delayed(const Duration(seconds: 3)); // 晚到响应落地
    // ignore: avoid_print
    print('取消窗口: responses=${s.responses} 残留连接=${s.openConnections}');
    expect(s.openConnections, 0,
        reason: '晚到的响应必须被消费并释放（api.dart:927 的守卫漏判"已取消"）');
  });

  test('窗口内连续重建 3 次 → 泄漏连接线性累积', () async {
    final s = await FakeSse.start(beforeRespond: const Duration(milliseconds: 700));
    addTearDown(s.stop);
    final a = mkApi(s);
    for (var i = 0; i < 3; i++) {
      final sub = a.eventsRaw().listen((_) {}, onError: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    // ignore: avoid_print
    print('重连 x3: responses=${s.responses} 残留连接=${s.openConnections}');
    expect(s.openConnections, 0, reason: '每次窗口内重建都不该留下半个 socket');
  });
}
