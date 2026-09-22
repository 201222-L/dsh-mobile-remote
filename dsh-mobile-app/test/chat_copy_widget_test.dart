// issue #15：手机端复制对话——三条诉求的回归测试
// 1) 助手/用户正文可长按选中（消息流包在 SelectionArea 里，不再只有代码块和思维链能选）；
// 2) 用户消息有自己的复制入口（此前只有助手消息有操作栏）；
// 3) 会话级「复制整段对话」（AppBar 入口，时间正序 + 角色标注）。
// 用本地假服务端喂 /api/history（与 history_page_test.dart 同一套接缝），跑真实 ChatScreen。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';

Future<HttpServer> _spawnServer() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // 与 history_page_test.dart 同款：同步 handler、不 drain（异步 handler 会同步抛错时
  // 让宿主返回 400，历史就加载不进来）。
  server.listen((req) {
    final isHistory = req.uri.path.endsWith('/history');
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(isHistory
          ? {
              'ok': true,
              'after': 2,
              'events': [
                {'seq': 1, 'type': 'user/message', 'data': {'text': '你好世界', 'messageId': 'u1'}},
                {'seq': 2, 'type': 'assistant/message', 'data': {'text': '收到', 'messageId': 'a1'}},
              ],
            }
          : {'ok': true}))
      ..close();
  });
  return server;
}

void main() {
  late HttpServer server;
  late List<String> copied;

  setUp(() async {
    // TestWidgetsFlutterBinding 默认把所有 HTTP 请求短路成 400（禁止真实网络）——
    // 这里是本机 loopback 假服务端，必须显式恢复真实 HttpClient。
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    server = await _spawnServer();
    api.baseUrl = 'http://127.0.0.1:${server.port}';
    api.token = '';
    copied = <String>[];
  });

  tearDown(() async {
    await server.close(force: true);
  });

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add('${(call.arguments as Map)['text']}');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<void> pumpChat(WidgetTester tester) async {
    final store = AppStore();
    await store.loadPrefs();
    store.sessionId = 's1';
    // testWidgets 默认跑在 fake-async 区：真实 HTTP（本地假服务端）的 Future 不会完成，
    // 必须用 runAsync 让 I/O 真正跑完，否则历史永远加载不进来、列表为空。
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: ChatScreen(store: store, onTitleChanged: () {})));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('消息流包在 SelectionArea 中，正文可长按选中', (tester) async {
    await pumpChat(tester);
    expect(find.byType(SelectionArea), findsWidgets);
    expect(find.text('你好世界'), findsOneWidget);
    expect(find.text('收到'), findsOneWidget);
  });

  testWidgets('用户消息有自己的复制入口，复制的是本条正文', (tester) async {
    mockClipboard(tester);
    await pumpChat(tester);
    // 用户 1 个 + 助手操作栏 1 个
    expect(find.byIcon(Icons.content_copy), findsNWidgets(2));
    await tester.tap(find.byIcon(Icons.content_copy).first);
    await tester.pump();
    expect(copied, equals(<String>['你好世界']));
  });

  testWidgets('复制整段对话：时间正序 + 角色标注', (tester) async {
    mockClipboard(tester);
    await pumpChat(tester);
    await tester.tap(find.byIcon(Icons.copy_all));
    await tester.pump();
    expect(copied, hasLength(1));
    expect(copied.single, contains('你：你好世界'));
    expect(copied.single, contains('助手：收到'));
    expect(copied.single.indexOf('你：'), lessThan(copied.single.indexOf('助手：')),
        reason: '导出必须是时间正序（_items 内部是最新在前）');
  });
}
