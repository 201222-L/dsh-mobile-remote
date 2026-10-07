// issue #25 widget 单测：composer 提交层的斜杠命令语义。
// 假后端（MockClient）同时记录 `/m/api/commands`（目录 GET / 执行 POST）与 `/m/api/send` 的调用，
// 断言：
//   (a) 已注册命令走命令通路，绝不出现在 /m/api/send 上；
//   (b) 不插入乐观用户气泡；
//   (c) 提交成功后清空草稿；
//   (d) 404 command-not-found → 明确提示且保留草稿（可改参数重发）；
//   (e) 未注册的 `/tmp` → 非阻塞提示 + 照常按普通消息发送（不阻塞消息）；
//   (f) ⊕ 命令菜单里的裸命令点选即执行（需要参数的命令仍只填输入框，副标题显示 input.hint）；
//   (g) 命令通路不触发「agent 空闲，已按普通消息发送」这类 steer 降级提示。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// 内核命令目录样本：compact = 裸命令（无 input），goal = 需要参数（有 input.hint）
const _compact = {'name': 'compact', 'description': 'compact the conversation'};
const _goal = {
  'name': 'goal',
  'description': 'set or view the goal',
  'input': {'hint': '[<objective>|clear]', 'attachments': true},
};
const _catalog = [_compact, _goal];

class _CommandBackend {
  _CommandBackend({
    this.commandStatus = 200,
    this.commandError,
    this.listStatus = 200,
    this.listError,
    this.commandKind = 'success',
    this.commandText = 'COMPACTED',
  }) {
    api = Api(client: MockClient(_handle))
      ..baseUrl = 'http://cmd.test'
      ..path = '/m'
      ..token = '';
  }

  late final Api api;
  final int commandStatus;
  final String? commandError;
  final int listStatus;
  final String? listError;
  final String commandKind;
  final String commandText;

  int commandListRequests = 0;
  final List<String> commandLines = [];
  final List<String> sendTexts = [];

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/m/api/history') {
      return _json({'ok': true, 'events': <Object>[], 'hasMore': false});
    }
    if (path == '/m/api/commands') {
      if (request.method == 'GET') {
        commandListRequests++;
        // 休眠/未挂载会话：GET 也 404（服务端 agents.get 未命中）
        if (listError != null) {
          return _json(
            {'error': listError, 'detail': 'session not found'},
            status: listStatus,
          );
        }
        return _json({'ok': true, 'commands': _catalog});
      }
      commandLines.add((jsonDecode(request.body) as Map)['line'] as String);
      if (commandError != null) {
        return _json(
          {'error': commandError, 'detail': 'unknown or malformed command'},
          status: commandStatus,
        );
      }
      return _json({
        'ok': true,
        'result': {
          'commandId': 'cmd-1',
          'result': {'kind': commandKind, 'text': commandText},
        },
      });
    }
    if (path == '/m/api/send') {
      sendTexts.add((jsonDecode(request.body) as Map)['text'] as String);
      return _json({'ok': true, 'messageId': 'mid-1'});
    }
    // 其余端点（queue / todos / session-config / usage…）：空壳即可，页面能起来就行
    return _json({'ok': true});
  }

  http.Response _json(Map<String, dynamic> body, {int status = 200}) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}

Future<void> _pumpChat(
  WidgetTester tester,
  AppStore store,
  _CommandBackend backend,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: const ValueKey('cmd-chat'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
}

AppStore _store() => AppStore()..sessionId = 'session-cmd';

Finder _composer() => find.byType(TextField);
Finder _sendButton() => find.byIcon(Icons.arrow_upward);

/// 输入框当前草稿（发送成功后应为空；失败时必须原样保留）
String _draft(WidgetTester tester) =>
    tester.widget<TextField>(_composer()).controller!.text;

/// 提交一行 + 等异步命令/发送与 toast 动画落地
Future<void> _submit(WidgetTester tester, String line) async {
  await tester.enterText(_composer(), line);
  await tester.pump();
  await tester.tap(_sendButton());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('issue #25：提交已注册命令 → 走命令通路、无用户气泡、成功清空草稿', (tester) async {
    final backend = _CommandBackend();
    await _pumpChat(tester, _store(), backend);

    await _submit(tester, '/compact');

    expect(backend.commandLines, ['/compact'], reason: '必须 POST /m/api/commands');
    expect(backend.sendTexts, isEmpty, reason: '命令绝不能落到 /m/api/send');
    expect(find.text('/compact'), findsNothing, reason: '不得插入乐观用户气泡');
    expect(_draft(tester), isEmpty, reason: '提交成功后清空草稿');
    expect(find.text('COMPACTED'), findsOneWidget, reason: '结果文本以 toast 呈现');
  });

  testWidgets('issue #25：命令 404 command-not-found → 提示 + 保留草稿', (tester) async {
    final backend = _CommandBackend(
      commandStatus: 404,
      commandError: 'command-not-found',
    );
    await _pumpChat(tester, _store(), backend);

    await _submit(tester, '/compact');

    expect(backend.commandLines, ['/compact']);
    expect(backend.sendTexts, isEmpty);
    expect(_draft(tester), '/compact', reason: '失败必须保留草稿供用户修改重发');
    expect(find.textContaining('命令目录已过期'), findsOneWidget);
  });

  testWidgets('issue #25：未注册的 /tmp → 非阻塞提示 + 照常走普通发送', (tester) async {
    final backend = _CommandBackend();
    await _pumpChat(tester, _store(), backend);

    await _submit(tester, '/tmp');

    expect(backend.commandLines, isEmpty, reason: '未注册名字不该尝试执行');
    expect(backend.sendTexts, ['/tmp'], reason: '不阻塞：必须照常发给模型');
    expect(find.textContaining('未知命令 /tmp'), findsOneWidget);
    expect(find.text('/tmp'), findsOneWidget, reason: '普通发送路径照旧插入乐观气泡');
    expect(_draft(tester), isEmpty);
  });

  testWidgets('issue #25：休眠会话（目录 404）不阻塞，按普通消息发送', (tester) async {
    final backend = _CommandBackend(
      listStatus: 404,
      listError: 'session-not-found',
    );
    await _pumpChat(tester, _store(), backend);

    // 目录取不到 → 无法判定这行是不是命令 → 放行普通发送（消息还能顺带唤醒休眠会话）
    await _submit(tester, '/compact');

    expect(backend.commandListRequests, 1);
    expect(backend.commandLines, isEmpty);
    expect(backend.sendTexts, ['/compact']);
    expect(find.textContaining('未知命令'), findsNothing);
  });

  testWidgets('issue #25：命令通路不发「agent 空闲，已按普通消息发送」steer 降级提示', (tester) async {
    final backend = _CommandBackend();
    await _pumpChat(tester, _store(), backend);

    await tester.enterText(_composer(), '/compact');
    await tester.pump();
    await tester.longPress(_sendButton()); // 长按 = 插队发送（mode: steer）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(backend.commandLines, ['/compact']);
    expect(find.textContaining('agent 空闲'), findsNothing);
    expect(backend.sendTexts, isEmpty);
  });

  testWidgets('issue #25：⊕ 菜单里的裸命令点选即执行；带参数命令只填输入框并显示 hint', (tester) async {
    final backend = _CommandBackend();
    await _pumpChat(tester, _store(), backend);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '命令'));
    await tester.pumpAndSettle();

    // 副标题：无 input 的 compact 显示 description；有 input 的 goal 显示内核给的 hint
    expect(find.text('/compact'), findsOneWidget);
    expect(find.text('compact the conversation'), findsOneWidget);
    expect(find.text('/goal'), findsOneWidget);
    expect(find.text('[<objective>|clear]'), findsOneWidget);

    await tester.tap(find.text('/compact'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(backend.commandLines, ['/compact'], reason: '裸命令点选即执行（不再只填输入框）');
    expect(backend.sendTexts, isEmpty);
    expect(_draft(tester), isEmpty, reason: '菜单执行不往输入框里塞文本');
    expect(find.text('COMPACTED'), findsOneWidget);
  });

  testWidgets('issue #25：命令自身失败（200 + kind=error）也要有 toast 反馈', (tester) async {
    final backend = _CommandBackend(
      commandKind: 'error',
      commandText: 'no argument given',
    );
    await _pumpChat(tester, _store(), backend);

    await _submit(tester, '/compact');

    // 移动端时间线在正常模式不渲染 command/run、command/done → 只能靠 toast
    expect(find.textContaining('no argument given'), findsOneWidget);
    expect(backend.sendTexts, isEmpty);
  });
}
