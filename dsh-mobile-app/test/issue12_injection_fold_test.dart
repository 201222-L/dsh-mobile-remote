// issue #12 回归：系统注入消息（内核 user 消息的 source.kind ≠ "user"）必须渲染成
// **可折叠块**（默认收起、点按展开），而不是当普通用户气泡铺满屏幕。
//
// 骨架对齐已验证的 chat_copy_widget_test.dart：**起假服务端与配置 api 必须放在 setUp**
// （真实 zone），放进 testWidgets 测试体（fake-async zone）会导致请求发不出去。
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
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    _historyCalls = 0;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) {
      // 按路径分派：非 history 请求若回历史载荷，客户端会据此解析出错误信息。
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

  Future<void> pumpChat(WidgetTester tester, List<Map<String, dynamic>> events) async {
    _events = events;
    final store = AppStore();
    await store.loadPrefs();
    store.sessionId = 's1';
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

  testWidgets('sourceKind=plugin：折叠块 + 类型标签 + 字数，默认不铺正文', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'plugin')]);
    expect(find.textContaining('插件注入'), findsOneWidget);
    expect(find.textContaining('${_injectedText.length} 字'), findsOneWidget);
    // 收起态不得渲染正文（这正是 issue 里"注入铺满对话流"的根因）
    expect(find.text(_injectedText), findsNothing);
  });

  testWidgets('点按标题行后展开正文', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'plugin')]);
    // 精确点注入块自己的标题行（页面别处也有箭头图标，不能按图标全局找）
    final header = find.textContaining('插件注入');
    final tappable = find.ancestor(of: header, matching: find.byType(InkWell)).first;
    await tester.tap(tappable);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(_injectedText), findsOneWidget, reason: '点按后应展开正文');
  });

  testWidgets('sourceKind=agent-instructions：标签区分为「系统指令注入」', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'agent-instructions')]);
    expect(find.textContaining('系统指令注入'), findsOneWidget);
    expect(find.text(_injectedText), findsNothing);
  });

  testWidgets('sourceKind=user：真人发言走普通气泡，不得被折叠', (tester) async {
    await pumpChat(tester, [_userEvent(sourceKind: 'user')]);
    expect(find.text(_injectedText), findsOneWidget);
    // 具体断言注入块的四种标签都不出现（比裸匹配"注入"精确，避免误伤其它文案）
    for (final label in ['插件注入', '系统指令注入', '工具注入', '系统注入']) {
      expect(find.textContaining(label), findsNothing, reason: '真人发言不该被折叠成「$label」块');
    }
  });

  testWidgets('旧内核（无 sourceKind）+ 噪声关键词：整条过滤，不渲染', (tester) async {
    await pumpChat(tester, [
      _userEvent(text: 'Current runtime context: 这是一段噪声快照，不该出现在对话流里。'),
    ]);
    expect(find.textContaining('Current runtime context'), findsNothing);
  });
}
