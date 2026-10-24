// GitLab #38 回归：取消 SSE 订阅必须释放 TCP socket。
// 不用 HttpServer.connectionsInfo()：未结束的 SSE 响应仍可能被统计为活动连接。
// 通过请求到达、客户端收到 hello、手动发送响应与 peer EOF 明确控制取消窗口。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile_app/api.dart';
import 'package:flutter_test/flutter_test.dart';

const _waitTimeout = Duration(seconds: 3);

class FakeSse {
  FakeSse._(this.server) {
    _requests = StreamIterator(_incoming.stream);
  }

  final ServerSocket server;
  final _incoming = StreamController<FakeSseConnection>();
  late final StreamIterator<FakeSseConnection> _requests;
  final _connections = <FakeSseConnection>[];
  final _serverErrors = <Object>[];
  int requests = 0;

  static Future<FakeSse> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSse._(server);
    server.listen((socket) {
      fake._connections.add(
        FakeSseConnection(socket, (connection) {
          fake.requests++;
          fake._incoming.add(connection);
        }),
      );
    }, onError: fake._serverErrors.add);
    return fake;
  }

  Future<FakeSseConnection> nextRequest() async {
    final received = await _requests.moveNext().timeout(
      _waitTimeout,
      onTimeout: () => fail('等待完整 SSE 请求头超时'),
    );
    expect(received, isTrue, reason: '服务端必须收到完整 SSE 请求头');
    return _requests.current;
  }

  int get openConnections =>
      _connections.where((connection) => !connection.isClosed).length;

  List<Object> get unexpectedErrors => [
    ..._serverErrors,
    for (final connection in _connections) ...connection.unexpectedErrors,
  ];

  Api api() => Api()
    ..baseUrl = 'http://127.0.0.1:${server.port}'
    ..token = '';

  Future<void> stop() async {
    await server.close();
    for (final connection in _connections) {
      connection.dispose();
    }
    await _requests.cancel();
    await _incoming.close();
  }
}

class FakeSseConnection {
  FakeSseConnection(this._socket, void Function(FakeSseConnection) onRequest) {
    final request = StringBuffer();
    var received = false;
    _socket.listen(
      (bytes) {
        if (received) return;
        request.write(utf8.decode(bytes, allowMalformed: true));
        if (!request.toString().contains('\r\n\r\n')) return;
        received = true;
        onRequest(this);
      },
      onError: _handleError,
      onDone: () {
        if (isClosed) return;
        if (!_disposing && !_cancellationExpected) {
          unexpectedErrors.add(StateError('对端在测试发起取消前已关闭连接'));
        }
        _markClosed();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final _closed = Completer<void>();
  final unexpectedErrors = <Object>[];
  bool _cancellationExpected = false;
  bool _disposing = false;
  bool responseSent = false;

  bool get isClosed => _closed.isCompleted;

  Future<void> sendHello() async {
    // 将来若客户端支持响应前立即中止，也允许连接在发送前就因取消而关闭。
    if (isClosed) return;
    expect(responseSent, isFalse);
    responseSent = true;
    final bytes = utf8.encode('data: {"type":"hello","capabilities":{}}\n\n');
    try {
      _socket
        ..add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: text/event-stream\r\n'
            'Transfer-Encoding: chunked\r\n'
            'Connection: keep-alive\r\n\r\n',
          ),
        )
        ..add(utf8.encode('${bytes.length.toRadixString(16)}\r\n'))
        ..add(bytes)
        ..add([13, 10]);
      await _socket.flush();
      // 不结束响应、不自行关闭连接，也不靠周期性写入驱动关闭观测。
    } catch (error) {
      _handleError(error);
    }
  }

  void prepareForCancellation() {
    expect(unexpectedErrors, isEmpty, reason: '取消前夹具不能已发生读写错误');
    expect(isClosed, isFalse, reason: '取消前目标连接必须仍然存活');
    _cancellationExpected = true;
  }

  void _handleError(Object error) {
    if (_disposing) return;
    // 只有显式发起取消后发生的传输断连才可接受；其它错误必须让断言失败。
    if (!(_cancellationExpected && error is SocketException)) {
      unexpectedErrors.add(error);
    }
    _markClosed();
  }

  void _markClosed() {
    if (isClosed) return;
    _closed.complete();
    _socket.destroy();
  }

  Future<void> waitForClose() async {
    await _closed.future.timeout(
      _waitTimeout,
      onTimeout: () => fail('取消后 TCP 连接未在期限内关闭'),
    );
    expect(unexpectedErrors, isEmpty, reason: '不能把意外异常当成取消成功');
  }

  void dispose() {
    _disposing = true;
    _markClosed();
  }
}

class SseClient {
  SseClient(Api api) {
    _subscription = api.eventsRaw().listen(
      (event) {
        events.add(event);
        _signalActivity();
      },
      onError: (Object error) {
        errors.add(error);
        _signalActivity();
      },
      onDone: () {
        ended = true;
        _signalActivity();
      },
    );
  }

  late final StreamSubscription<Map<String, dynamic>> _subscription;
  final _activity = Completer<void>();
  final events = <Map<String, dynamic>>[];
  final errors = <Object>[];
  bool ended = false;

  void _signalActivity() {
    if (!_activity.isCompleted) _activity.complete();
  }

  void expectHealthy() {
    expect(errors, isEmpty, reason: '取消前不能吞掉客户端错误');
    expect(ended, isFalse, reason: '取消前 SSE 流必须仍然存活');
  }

  Future<void> waitForHello() async {
    await _activity.future.timeout(
      _waitTimeout,
      onTimeout: () => fail('等待有效 SSE hello 超时'),
    );
    expectHealthy();
    expect(events, isNotEmpty, reason: '必须实际收到 SSE 帧而不只是请求已到达');
    expect(events.first['type'], 'hello');
  }

  Future<void> cancel() => _subscription.cancel();
}

void main() {
  test('对照：响应到达后取消（正常路径）→ 连接释放', () async {
    final s = await FakeSse.start();
    addTearDown(s.stop);
    final client = SseClient(s.api());
    addTearDown(client.cancel);
    final connection = await s.nextRequest();
    await connection.sendHello();
    await client.waitForHello();
    expect(s.requests, 1);
    expect(s.openConnections, 1);

    connection.prepareForCancellation();
    await client.cancel();
    await connection.waitForClose();
    expect(client.errors, isEmpty);
    expect(s.unexpectedErrors, isEmpty);
    expect(s.openConnections, 0, reason: '正常取消必须释放已开始接收响应的连接');
  });

  test('取消窗口：响应到达前取消（resume/switchBase/disposeBridge 的动作）', () async {
    final s = await FakeSse.start();
    addTearDown(s.stop);
    final client = SseClient(s.api());
    addTearDown(client.cancel);
    final connection = await s.nextRequest();
    expect(s.requests, 1);
    expect(connection.responseSent, isFalse);
    client.expectHealthy();
    expect(client.events, isEmpty);

    connection.prepareForCancellation();
    await client.cancel();
    // cancel 已经完成，此后才放行响应，确定覆盖晚到响应分支。
    await connection.sendHello();
    await connection.waitForClose();
    expect(client.errors, isEmpty);
    expect(client.events, isEmpty);
    expect(s.unexpectedErrors, isEmpty);
    expect(s.openConnections, 0, reason: '取消响应前的请求必须释放连接');
  });

  test('窗口内连续重建 3 次 → 不累积泄漏连接', () async {
    final s = await FakeSse.start();
    addTearDown(s.stop);
    final api = s.api();
    final connections = <FakeSseConnection>[];
    final clients = <SseClient>[];
    for (var i = 0; i < 3; i++) {
      final client = SseClient(api);
      clients.add(client);
      addTearDown(client.cancel);
      final connection = await s.nextRequest();
      connections.add(connection);
      expect(s.requests, i + 1);
      expect(connection.isClosed, isFalse);
      expect(connection.responseSent, isFalse);
      client.expectHealthy();
      expect(client.events, isEmpty);
      connection.prepareForCancellation();
      await client.cancel();
    }
    // 三条请求都在窗口内取消后才统一放行，保留并发累积泄漏的回归场景。
    for (final connection in connections) {
      await connection.sendHello();
    }
    await Future.wait(
      connections.map((connection) => connection.waitForClose()),
    );
    for (final client in clients) {
      expect(client.errors, isEmpty);
      expect(client.events, isEmpty);
    }
    expect(s.unexpectedErrors, isEmpty);
    expect(s.openConnections, 0, reason: '每次窗口内重建都必须释放自己的连接');
  });
}
