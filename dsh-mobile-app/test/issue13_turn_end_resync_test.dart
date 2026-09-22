// 第 3 层：widget 层复现"turn/end 触发兜底补拉"（issue #13 建议 3）。
// 断言：本轮只有真人提问、没有回复 → 推一帧 turn/end 后 ChatScreen 会做一次**全量重载**
// （/api/history 不带 after=）；对照组（不推 turn/end）不会多出全量重载。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';

import 'sse_test_host.dart';

// 历史里只有一条真人提问、没有任何回复 → needsTurnEndResync() 为真
Map<String, dynamic> historyPayload() => {
      'ok': true,
      'after': 10,
      'events': [
        {
          'seq': 10,
          'type': 'user/message',
          'data': {'text': '压缩后这个问题还在吗', 'messageId': 'u10'},
        },
      ],
    };

void main() {
  late SseTestHost host;

  setUp(() async {
    // 绑定默认把 HTTP 短路成 400；本机 loopback 假服务端必须显式恢复真实 HttpClient。
    // 服务端与 baseUrl 都必须在 setUp（真实 zone）里配好。
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    host = await SseTestHost.start(
      respond: (uri) => uri.path.endsWith('/history') ? historyPayload() : {'ok': true},
    );
    api.baseUrl = 'http://127.0.0.1:${host.server.port}';
    api.token = '';
  });

  tearDown(() async {
    await host.stop();
  });

  Future<AppStore> pumpChat(WidgetTester tester) async {
    final store = AppStore();
    await store.loadPrefs();
    store.sessionId = 's1';
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(store: store, onTitleChanged: () {}),
      ));
      await waitFor(() => host.fullHistoryReloads >= 1, label: '首屏 /api/history 全量加载');
      // 连上 SSE（真 I/O 必须在 runAsync 里跑）
      store.connect();
      await host.push({'type': 'hello', 'capabilities': {}});
      await waitFor(() => store.connState == 'connected', label: 'connState=connected');
    });
    await tester.pump();
    addTearDown(store.disposeBridge);
    return store;
  }

  testWidgets('turn/end 且本轮无回复 → 兜底补拉（多一次全量重载）', (tester) async {
    final store = await pumpChat(tester);
    expect(store.connState, 'connected');

    late int before;
    await tester.runAsync(() async {
      before = host.fullHistoryReloads;
      await host.push({
        'type': 'session/event',
        'sessionId': 's1',
        'event': {'type': 'turn/end', 'seq': 11, 'data': {}},
      });
      await waitFor(
        () => host.fullHistoryReloads > before,
        label: 'turn/end 后的兜底补拉（第 ${before + 1} 次全量重载）',
      );
    });
    expect(host.fullHistoryReloads, greaterThan(before),
        reason: 'needsTurnEndResync=true 时必须补拉一次 /api/history（无 after=）'
            '；实测 turn/end 前 $before 次、后 ${host.fullHistoryReloads} 次');
  });

  testWidgets('对照：不推 turn/end → 不会多出全量重载', (tester) async {
    await pumpChat(tester);
    late int before;
    await tester.runAsync(() async {
      before = host.fullHistoryReloads;
      // 只推一条普通增量帧（不触发兜底），确认第 1 个用例的增量来自 turn/end 而非环境噪声
      await host.push({
        'type': 'session/event',
        'sessionId': 's1',
        'event': {'type': 'tool/call', 'seq': 11, 'data': {'name': 'read'}},
      });
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    expect(host.fullHistoryReloads, before,
        reason: '没有 turn/end 就不该有补拉（实测 $before → ${host.fullHistoryReloads}）');
  });
}
