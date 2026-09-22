// 第 2 层：store 层（仍是普通 test()，不带 widget）。
// 结论：store.connect() / _onFrame(hello) / chat 监听器广播都正常，只要假服务端按
// sse_test_host.dart 的写法（bufferOutput=false）推帧。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/store.dart';

import 'sse_test_host.dart';

void main() {
  // 需要绑定才能用 SharedPreferences 的 mock（但不用 testWidgets → 无 fake async）
  TestWidgetsFlutterBinding.ensureInitialized();

  late SseTestHost host;

  setUp(() async {
    // 绑定默认把所有 HTTP 请求短路成 400，loopback 假服务端必须显式恢复真实 HttpClient
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    host = await SseTestHost.start();
    api.baseUrl = 'http://127.0.0.1:${host.server.port}';
    api.token = '';
  });

  tearDown(() async {
    await host.stop();
  });

  test('connect(): hello 后 connState=connected，session/event 到达 chat 监听器', () async {
    final store = AppStore();
    addTearDown(store.disposeBridge);
    final seen = <ChatEvent>[];
    store.addChatListener(seen.add);
    store.sessionId = 's1';

    store.connect();
    expect(store.connState, 'connecting');

    await host.push({
      'type': 'hello',
      'capabilities': {
        'eventTimeline': {'detail': true},
      },
    });
    await waitFor(() => store.connState == 'connected', label: 'connState=connected');

    await host.push({
      'type': 'session/event',
      'sessionId': 's1',
      'event': {'type': 'user/message', 'seq': 7, 'data': {'text': '你好'}},
    });
    await waitFor(
      () => seen.any((e) => e.type == 'user/message'),
      label: 'chat 监听器收到 user/message',
    );

    // hello 在 store 侧被翻译成 _capabilities 广播（不是原样透传）
    expect(seen.any((e) => e.type == '_capabilities'), isTrue);
    final msg = seen.firstWhere((e) => e.type == 'user/message');
    expect(msg.sessionId, 's1');
    expect(msg.seq, 7);
    expect(msg.data?['text'], '你好');
    expect(store.connState, 'connected');
    expect(host.sseConnections, 1);
  });

  test('connect() 里的帧不会因为 store 未配置 sessionId 而丢', () async {
    final store = AppStore();
    addTearDown(store.disposeBridge);
    final seen = <ChatEvent>[];
    store.addChatListener(seen.add);

    store.connect();
    await host.push({'type': 'hello', 'capabilities': {}});
    await waitFor(() => store.connState == 'connected', label: 'connState=connected');
    await host.push({
      'type': 'session/event',
      'sessionId': 'other',
      'event': {'type': 'assistant/message', 'seq': 12, 'data': {'text': '台风'}},
    });
    await waitFor(
      () => seen.any((e) => e.type == 'assistant/message'),
      label: 'sessionId 不匹配也广播（由页面各自过滤）',
    );
    expect(seen.firstWhere((e) => e.type == 'assistant/message').sessionId, 'other');
  });
}
