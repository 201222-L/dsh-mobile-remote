// SSE 端到端测试的假宿主（供 sse_*.dart / issue13_*.dart 复用；不是测试文件本身）。
//
// ⚠️ 关键：`HttpResponse.bufferOutput = false`。
// dart:io 的 HttpResponse 默认 `bufferOutput = true`，此时小体积（< 8KB）SSE 帧**既不会**
// 随 `add()` 上线，**也不会**被显式 `await flush()` 推出去——服务端看起来一切正常，
// 客户端一个字节都收不到（实测证据见 sse_events_raw_test.dart 第 2 个用例）。
// 这曾是本仓库 SSE widget 测试"有时完全收不到帧 / connState 一直是 connecting"的真因。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

class SseTestHost {
  SseTestHost._(this.server);

  final HttpServer server;

  /// 收到的全部请求（含 query），用于断言"某个端点被请求了几次/带没带 after="。
  final List<Uri> requests = [];

  /// 已经推给客户端的帧类型（排障用）。
  final List<String> pushedTypes = [];

  int sseConnections = 0;

  /// 全量重载次数（/api/history 且**不带 after=**）——ChatScreen._load(reset:) 的指纹。
  int get fullHistoryReloads => requests
      .where((u) => u.path.endsWith('/history') && !u.queryParameters.containsKey('after'))
      .length;

  int get historyRequests =>
      requests.where((u) => u.path.endsWith('/history')).length;

  final Completer<void> _sseReady = Completer<void>();
  StreamController<List<int>>? _ctrl;

  /// [respond] 为普通 JSON 端点的应答；[bufferOutput] 仅供"复现 dart:io 缓冲坑"用。
  static Future<SseTestHost> start({
    Map<String, dynamic> Function(Uri uri)? respond,
    bool bufferOutput = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = SseTestHost._(server);
    server.listen((req) async {
      host.requests.add(req.uri);
      if (req.uri.path.endsWith('/events')) {
        host.sseConnections++;
        host._serveSse(req, bufferOutput);
        return;
      }
      try {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(respond?.call(req.uri) ?? {'ok': true}));
        await req.response.close();
      } catch (_) {
        /* 客户端已断开 */
      }
    });
    return host;
  }

  void _serveSse(HttpRequest req, bool bufferOutput) {
    final res = req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('text', 'event-stream')
      ..headers.set('cache-control', 'no-cache')
      ..bufferOutput = bufferOutput;
    final ctrl = StreamController<List<int>>();
    _ctrl = ctrl;
    // 客户端断开后写入会报错：吞掉，避免污染测试结果
    res.done.catchError((_) {});
    ctrl.stream.listen((bytes) {
      try {
        res.add(bytes);
        res.flush().catchError((_) {});
      } catch (_) {}
    });
    if (!_sseReady.isCompleted) _sseReady.complete();
  }

  /// 推一帧 `data: {...}\n\n`（等连接建立后推，避免帧丢在无人监听的窗口）。
  Future<void> push(
    Map<String, dynamic> frame, {
    Duration settle = const Duration(milliseconds: 40),
  }) async {
    await _sseReady.future.timeout(const Duration(seconds: 5));
    _ctrl!.add(utf8.encode('data: ${jsonEncode(frame)}\n\n'));
    pushedTypes.add(frame['type'] as String? ?? '?');
    await Future<void>.delayed(settle);
  }

  /// 推原始字节（用于验证跨 chunk 分帧）。
  Future<void> pushRaw(
    String raw, {
    Duration settle = const Duration(milliseconds: 40),
  }) async {
    await _sseReady.future.timeout(const Duration(seconds: 5));
    _ctrl!.add(utf8.encode(raw));
    await Future<void>.delayed(settle);
  }

  Future<void> stop() async {
    try {
      await _ctrl?.close();
    } catch (_) {}
    await server.close(force: true);
  }
}

/// 条件轮询等待（不用固定 sleep）。
Future<void> waitFor(
  bool Function() cond, {
  String label = '条件',
  Duration timeout = const Duration(seconds: 6),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('等待「$label」超时（${timeout.inMilliseconds}ms）');
}
