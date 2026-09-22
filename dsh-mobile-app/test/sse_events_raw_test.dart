// 第 1 层：纯 API 层 SSE（普通 test()，不带 Flutter widget 绑定）。
// 结论：eventsRaw() 的连接/解析逻辑本身是好的——只要假服务端把 response.bufferOutput 设成
// false，hello / session/event 都能收到，跨 chunk 分帧也能拼回。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/api.dart';

import 'sse_test_host.dart';

void main() {
  test('eventsRaw: 收到 hello + session/event，跨 chunk 分帧能拼回', () async {
    final host = await SseTestHost.start();
    addTearDown(host.stop);
    final a = Api()
      ..baseUrl = 'http://127.0.0.1:${host.server.port}'
      ..token = '';

    final got = <Map<String, dynamic>>[];
    final sub = a.eventsRaw().listen(
          got.add,
          onError: (e) => got.add({'type': 'ERROR', 'detail': '$e'}),
        );
    addTearDown(sub.cancel);

    await host.push({
      'type': 'hello',
      'capabilities': {
        'eventTimeline': {'detail': true},
      },
    });

    // 一帧故意拆成两个 socket chunk：验证 api.dart 里 StringBuffer 的 buf 分帧
    final frame = 'data: ${jsonEncode({
          'type': 'session/event',
          'sessionId': 's1',
          'event': {'type': 'user/message', 'seq': 3, 'data': {'text': 'hi'}},
        })}\n\n';
    await host.pushRaw(frame.substring(0, 18));
    await host.pushRaw(frame.substring(18));

    await waitFor(() => got.length >= 2, label: 'eventsRaw 收到 2 帧');

    expect(got.map((e) => e['type']).toList(), ['hello', 'session/event']);
    expect(got[1]['sessionId'], 's1');
    expect((got[1]['event'] as Map)['type'], 'user/message');
    expect((got[1]['event'] as Map)['seq'], 3);
    expect(host.sseConnections, 1);
  });

  test('环境坑回归：bufferOutput=true（dart:io 默认）→ 帧不上线', () async {
    // 这条用"反例"固化本仓库 SSE 测试最大的坑：假服务端忘了 bufferOutput=false 时，
    // 小帧（<8KB）会一直留在服务端缓冲区里，客户端 connState 永远停在 connecting。
    // 若某天这条失败，说明 dart:io 的缓冲行为变了——是新闻，不是回归。
    final host = await SseTestHost.start(bufferOutput: true);
    addTearDown(host.stop);
    final a = Api()
      ..baseUrl = 'http://127.0.0.1:${host.server.port}'
      ..token = '';

    final got = <Map<String, dynamic>>[];
    final sub = a.eventsRaw().listen(got.add, onError: (e) => got.add({'type': 'ERROR'}));
    addTearDown(sub.cancel);

    await host.push({'type': 'hello', 'capabilities': {}});
    await host.push({
      'type': 'session/event',
      'sessionId': 's1',
      'event': {'type': 'turn/end', 'seq': 9},
    });
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(host.sseConnections, 1, reason: '服务端确实收到了 SSE 请求');
    expect(got, isEmpty,
        reason: 'bufferOutput=true 时 ≤8KB 的帧不会上线（也不受 flush() 影响）');
  });
}
