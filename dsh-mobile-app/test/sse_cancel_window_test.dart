// GitLab #38 回归：取消 SSE 订阅必须释放 TCP socket（响应已到达和仍在等待时都成立）。
// 不用 HttpServer.connectionsInfo() 计数：未结束的 SSE HttpResponse 会继续被统计为活动连接；
// 这里直接通过原始 TCP socket 的 peer EOF 观察连接关闭。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/api.dart';

class FakeSse {
  FakeSse._(this.server);

  final ServerSocket server;
  final Set<Socket> _openSockets = {};
  final List<Socket> _sockets = [];
  final List<Timer> _timers = [];
  int requests = 0;

  static Future<FakeSse> start({required Duration beforeRespond}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSse._(server);
    server.listen((socket) {
      fake._openSockets.add(socket);
      fake._sockets.add(socket);
      final request = StringBuffer();
      var responseStarted = false;
      var closed = false;
      Timer? heartbeat;

      void markClosed() {
        if (closed) return;
        closed = true;
        heartbeat?.cancel();
        fake._openSockets.remove(socket);
      }

      void writeChunk(String text) {
        if (closed) return;
        final bytes = utf8.encode(text);
        try {
          socket
            ..add(utf8.encode('${bytes.length.toRadixString(16)}\r\n'))
            ..add(bytes)
            ..add([13, 10]);
          socket.flush().catchError((_) => markClosed());
        } catch (_) {
          markClosed();
        }
      }

      socket.listen(
        (bytes) {
          if (responseStarted) return;
          request.write(utf8.decode(bytes, allowMalformed: true));
          if (!request.toString().contains('\r\n\r\n')) return;
          responseStarted = true;
          fake.requests++;
          Future<void>.delayed(beforeRespond).then((_) {
            if (closed) return;
            try {
              socket.add(
                utf8.encode(
                  'HTTP/1.1 200 OK\r\n'
                  'Content-Type: text/event-stream\r\n'
                  'Transfer-Encoding: chunked\r\n'
                  'Connection: keep-alive\r\n\r\n',
                ),
              );
            } catch (_) {
              markClosed();
              return;
            }
            writeChunk('data: {"type":"hello","capabilities":{}}\n\n');
            heartbeat = Timer.periodic(
              const Duration(milliseconds: 250),
              (_) => writeChunk(': ping\n\n'),
            );
            fake._timers.add(heartbeat!);
          });
        },
        onError: (_) => markClosed(),
        onDone: markClosed,
        cancelOnError: true,
      );
    });
    return fake;
  }

  int get openConnections => _openSockets.length;

  Api api() => Api()
    ..baseUrl = 'http://127.0.0.1:${server.port}'
    ..token = '';

  Future<void> stop() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    for (final socket in _sockets) {
      socket.destroy();
    }
    await server.close();
  }
}

void main() {
  test('对照：响应到达后取消（正常路径）→ 连接释放', () async {
    final s = await FakeSse.start(beforeRespond: Duration.zero);
    addTearDown(s.stop);
    final sub = s.api().eventsRaw().listen((_) {}, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await sub.cancel();
    await Future<void>.delayed(const Duration(seconds: 1));
    // ignore: avoid_print
    print('对照: requests=${s.requests} 残留连接=${s.openConnections}');
    expect(s.requests, 1, reason: '必须先建立一条 SSE 连接');
    expect(s.openConnections, 0, reason: '正常取消必须释放连接');
  });

  test('取消窗口：响应到达前取消（resume/switchBase/disposeBridge 的动作）', () async {
    final s = await FakeSse.start(
      beforeRespond: const Duration(milliseconds: 900),
    );
    addTearDown(s.stop);
    final sub = s.api().eventsRaw().listen((_) {}, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await sub.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    print('取消窗口: requests=${s.requests} 残留连接=${s.openConnections}');
    expect(s.requests, 1, reason: '必须在响应窗口内建立一条 SSE 连接');
    expect(s.openConnections, 0, reason: '取消响应前的请求必须释放连接');
  });

  test('窗口内连续重建 3 次 → 不累积泄漏连接', () async {
    final s = await FakeSse.start(
      beforeRespond: const Duration(milliseconds: 700),
    );
    addTearDown(s.stop);
    final api = s.api();
    for (var i = 0; i < 3; i++) {
      final sub = api.eventsRaw().listen((_) {}, onError: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    // ignore: avoid_print
    print('重连 x3: requests=${s.requests} 残留连接=${s.openConnections}');
    expect(s.requests, 3, reason: '必须实际建立三条 SSE 连接');
    expect(s.openConnections, 0, reason: '每次窗口内重建都不该留下半个 socket');
  });
}
