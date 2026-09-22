// 子代理行可点 → 跳到该子代理会话（#11 复核补正）。
//
// 两条不变量：
// 1) 打开面板本身不切换会话；
// 2) 点子代理行切到该子会话，从子会话返回时**恢复原会话**（与「分支」流程同款语义：
//    子代理会话是顺路看一眼，不该改变主会话）。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/screens/session_tools_sheet.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const parentId = 'session-parent';
const childId = 'child-abc';

http.Response _json(Map<String, dynamic> body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

/// 顶掉网络：只对 /api/subagents 给出一条真实子代理，其余一律 `{ok:true}`。
Api _fakeApi() => Api(client: MockClient((request) async {
      if (request.url.path == '/m/api/subagents') {
        return _json({
          'ok': true,
          'subagents': [
            {'id': childId, 'title': 'Audit app core and UI', 'status': 'inactive'},
          ],
        });
      }
      // 子会话页会立刻拉历史：这里必须回**合法**响应，否则 ChatScreen 判定
      // 「该会话暂不可用」并自我 pop（chat_screen.dart 的 _load 失败分支），
      // onReturn 随即把会话切回父会话，测试会看到「切过去了又弹回来」。
      if (request.url.path == '/m/api/history') {
        return _json({'ok': true, 'events': <Object>[], 'hasMore': false});
      }
      return _json({'ok': true});
    }))
      ..baseUrl = 'http://subagent.test'
      ..path = '/m'
      ..token = '';

Future<void> _openSheet(WidgetTester tester, AppStore store, Api apiClient) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showSessionToolsSheet(ctx, store, parentId, apiClient: apiClient),
          child: const Text('open-sheet'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open-sheet'));
  await _settle(tester); // 面板弹出动画：必须逐帧推进，单次 pump 面板还在视口外
  expect(find.text('会话工具'), findsOneWidget, reason: '面板应弹出');
  expect(find.text('子代理'), findsOneWidget, reason: '应有子代理页签');
  await tester.tap(find.byType(Tab).at(1)); // 点 Tab 组件本身，点文字命中不稳
  await _settle(tester); // 页签切换 + 加载
}

/// 逐帧推进若干次：单次 pump(长时长) 不会把动画推到终态，命中测试会落在视口外。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  // openChat → store.setSession 会 await SharedPreferences：不 mock 的话 push 之前就停住，
  // 测试里表现为「会话已切、ChatScreen 没出现」。
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('点子代理行 → 切到该子代理会话，返回后恢复原会话', (tester) async {
    final fakeApi = _fakeApi();
    final store = AppStore()..sessionId = parentId;

    await _openSheet(tester, store, fakeApi);
    expect(find.text('Audit app core and UI'), findsOneWidget);
    expect(store.sessionId, parentId, reason: '打开面板本身不应切换会话');

    await tester.tap(find.text('Audit app core and UI'));
    await _settle(tester);
    expect(store.sessionId, childId, reason: '点子代理行应切到该子会话');
    expect(find.byType(ChatScreen), findsOneWidget, reason: '应推入子会话的会话页');

    // 返回：onReturn 恢复原会话
    final nav = Navigator.of(tester.element(find.byType(ChatScreen)));
    nav.pop();
    await _settle(tester);
    expect(store.sessionId, parentId, reason: '从子代理会话返回后必须恢复原会话');
  });
}
