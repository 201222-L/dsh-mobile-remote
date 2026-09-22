// issue #12 回归：系统注入消息（内核 user 消息的 source.kind ≠ "user"）不得以普通气泡铺满屏幕。
//
// v3.1.5（PR #24 时间线）起语义升级为**双模式**：
//   - 普通模式（默认）：注入消息整条不渲染（比"折叠块"更干净，issue 原话允许"直接过滤"）；
//   - 调试模式（store.timelineDebug=true）：渲染为可折叠块（类型标签 + 字数，默认收起、点按展开）。
// 因此本文件按两种模式分别断言。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';

const _injectedText = '[SCHEDULE REMINDER] 18:00 前提交日报，这段注入文本要足够长才看得出是否铺屏。';

late HttpServer _server;
List<Map<String, dynamic>> _events = const [];
int _historyCalls = 0;

Map<String, dynamic> _userEvent({String? sourceKind, String text = _injectedText}) => {
      'seq': 1,
      'type': 'user/message',
      'data': {
        'text': text,
        'messageId': 'u1',
        'sourceKind': ?sourceKind,
      },
    };

void main() {
  setUp(() async {
    // 服务端与 api 配置必须在 setUp（真实 zone）；放进测试体请求发不出去。
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    _historyCalls = 0;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) {
      final isHistory = req.uri.path.endsWith('/history');
      if (isHistory) _historyCalls++;
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(isHistory ? {'ok': true, 'after': 1, 'events': _events} : {'ok': true}))
        ..close();
    });
    api.baseUrl = 'http://127.0.0.1:${_server.port}';
    api.token = '';
  });

  tearDown(() async {
    await _server.close(force: true);
  });

  Future<void> pumpChat(WidgetTester tester, List<Map<String, dynamic>> events,
      {bool debug = false}) async {
    _events = events;
    final store = AppStore();
    await store.loadPrefs();
    store.sessionId = 's1';
    store.timelineDebug = debug; // 普通模式（默认）不渲染注入消息；调试模式渲染折叠块
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: ChatScreen(store: store, onTitleChanged: () {})));
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (_historyCalls < 1 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('普通模式：注入消息整条不渲染（不占屏、也不出现注入标签）', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'plugin')]);
    expect(find.text(_injectedText), findsNothing);
    for (final label in ['插件注入', '系统指令注入', '工具注入', '系统注入']) {
      expect(find.textContaining(label), findsNothing);
    }
  });

  testWidgets('调试模式：注入消息渲染为折叠块 + 类型标签 + 字数，默认不铺正文', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'plugin')], debug: true);
    expect(find.textContaining('插件注入'), findsOneWidget);
    expect(find.textContaining('${_injectedText.length} 字'), findsOneWidget);
    expect(find.text(_injectedText), findsNothing, reason: '收起态不得渲染正文');
  });

  testWidgets('调试模式：点按标题行后展开正文', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'plugin')], debug: true);
    final header = find.textContaining('插件注入');
    await tester.tap(find.ancestor(of: header, matching: find.byType(InkWell)).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(_injectedText), findsOneWidget, reason: '点按后应展开正文');
  });

  testWidgets('调试模式：sourceKind=agent-instructions 标签区分为「系统指令注入」', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'agent-instructions')], debug: true);
    expect(find.textContaining('系统指令注入'), findsOneWidget);
    expect(find.text(_injectedText), findsNothing);
  });

  testWidgets('真人发言（sourceKind=user）两种模式都走普通气泡，不得被折叠或隐藏', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'user')]);
    expect(find.text(_injectedText), findsOneWidget);
    for (final label in ['插件注入', '系统指令注入', '工具注入', '系统注入']) {
      expect(find.textContaining(label), findsNothing);
    }
  });

  testWidgets('旧内核（无 sourceKind）+ 噪声关键词：整条过滤，不渲染', (tester) async {
    await pumpChat(tester, [
      _userEvent(text: 'Current runtime context: 这是一段噪声快照，不该出现在对话流里。'),
    ]);
    expect(find.textContaining('Current runtime context'), findsNothing);
  });
}
