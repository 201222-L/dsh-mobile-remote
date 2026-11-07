// issue #54（M3 Batch 1）：对话页专用工具卡（折叠行/退出码/命中数/diff/通用降级/能力位）。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _allTools = [
  'bash',
  'pwsh',
  'read',
  'write',
  'edit',
  'grep',
  'glob',
  'web_fetch',
  'web_search',
  'read_image',
];

class _ToolsBackend {
  _ToolsBackend({
    List<String>? tools,
    this.writeDiffTruncated = false,
    this.readResultSummary,
  }) : tools = tools ?? _allTools;

  final List<String> tools;
  final bool writeDiffTruncated;

  /// 模拟旧服务端/异常数据：read 结果竟带 exitCode，App 必须按 call kind 忽略。
  final Map<String, dynamic>? readResultSummary;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://tools-chat.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
      unknownEvents: true,
      callCorrelation: true,
    )
    ..toolCardsCapabilities = tools.isEmpty
        ? const ToolCardsCapabilities()
        : ToolCardsCapabilities(version: 1, tools: tools.toSet());

  Map<String, dynamic> _summary(Map<String, dynamic> summary) =>
      {'summary': summary};

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      return _json({
        'ok': true,
        'hasMore': false,
        'turnTails': const <String, dynamic>{},
        'events': [
          {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}},
          {
            'seq': 2,
            'type': 'user/message',
            'data': {'messageId': 'u1', 'text': '跑一下', 'sourceKind': 'user'},
          },
          {
            'seq': 3,
            'type': 'tool/call',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-bash',
              'name': 'bash',
              'arguments': '{"command":"ls -la"}',
              ..._summary({
                'kind': 'command',
                'tool': 'bash',
                'command': 'ls -la',
                'workdir': 'src',
              }),
            },
          },
          {
            'seq': 4,
            'type': 'tool/result',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-bash',
              'name': 'bash',
              'text': 'BOOM\n[exit code: 2]',
              'isError': false,
              ..._summary({'exitCode': 2}),
            },
          },
          {
            'seq': 5,
            'type': 'tool/call',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-write',
              'name': 'write',
              ..._summary({
                'kind': 'file',
                'tool': 'write',
                'filePath': 'src/a.ts',
                'sizeKb': 1,
                if (writeDiffTruncated)
                  'diffTruncated': true
                else
                  'diff': '--- /dev/null\n+++ b/src/a.ts\n@@ -0,0 +1,1 @@\n+hi\n',
              }),
            },
          },
          {
            'seq': 6,
            'type': 'tool/result',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-write',
              'name': 'write',
              'text': 'wrote a.ts',
              'isError': false,
            },
          },
          {
            'seq': 7,
            'type': 'tool/call',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-grep',
              'name': 'grep',
              ..._summary({
                'kind': 'search',
                'tool': 'grep',
                'pattern': 'foo',
                'path': 'lib',
              }),
            },
          },
          {
            'seq': 8,
            'type': 'tool/result',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-grep',
              'name': 'grep',
              'text': 'Found 3 matches',
              'isError': false,
              ..._summary({'resultCount': 3}),
            },
          },
          {
            'seq': 9,
            'type': 'tool/call',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-read',
              'name': 'read',
              ..._summary({
                'kind': 'file',
                'tool': 'read',
                'filePath': 'src/b.ts',
                'offset': 2,
                'limit': 4,
              }),
            },
          },
          {
            'seq': 10,
            'type': 'tool/result',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-read',
              'name': 'read',
              'text': 'line two',
              'isError': false,
              if (readResultSummary != null)
                ..._summary(readResultSummary!),
            },
          },
          {
            'seq': 11,
            'type': 'tool/call',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-mystery',
              'name': 'mystery',
              'arguments': '{"a":1}',
            },
          },
          {
            'seq': 12,
            'type': 'tool/result',
            'data': {
              'turn': 1,
              'step': 1,
              'callId': 'call-mystery',
              'name': 'mystery',
              'text': 'ok',
              'isError': false,
            },
          },
          {
            'seq': 13,
            'type': 'turn/end',
            'data': {
              'turn': 1,
              'reason': {'kind': 'completed'},
            },
          },
        ],
      });
    }
    if (request.url.path == '/m/api/notifications') {
      return _json({'ok': true, 'items': <Object>[]});
    }
    if (request.url.path == '/m/api/queue') {
      return _json({'ok': true, 'rows': <Object>[]});
    }
    if (request.url.path == '/m/api/todos') {
      return _json({'ok': true, 'todos': <Object>[]});
    }
    return _json({'ok': true});
  }

  static http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _pumpChat(
  WidgetTester tester,
  AppStore store,
  _ToolsBackend backend,
) async {
  // 历史夹具含 6 张工具卡：拉高测试视口，避免 SliverList 懒构建导致卡片未创建。
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: const ValueKey('tools-chat'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Finder _toolCard(String callId, int seq) =>
    find.byKey(ValueKey<String>('tool:$callId:$seq'));

void main() {
  testWidgets('专用卡折叠行：命令/退出码/文件统计/搜索命中数，未知工具回退', (tester) async {
    final backend = _ToolsBackend();
    final store = AppStore()
      ..sessionId = 'session-tools'
      // 完全展开：M1 的标准档会把已完成轮次的过程折叠，工具卡不构建。
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    await _pumpChat(tester, store, backend);

    expect(find.text(r'$ ls -la'), findsOneWidget);
    expect(find.text('exit 2'), findsOneWidget);
    expect(find.text('src/a.ts'), findsWidgets);
    expect(find.text('1KB'), findsOneWidget);
    expect(find.text('foo · lib'), findsOneWidget);
    expect(find.text('3 个匹配'), findsOneWidget);
    expect(find.text('src/b.ts · 行 2–5'), findsOneWidget);
    // 未知工具仍显示通用卡标题（不因缺 summary 整卡失败）。
    expect(find.text('mystery'), findsOneWidget);
  });

  testWidgets('展开：command 显示终端输出，write 内联统一 diff', (tester) async {
    final backend = _ToolsBackend();
    final store = AppStore()
      ..sessionId = 'session-tools'
      // 完全展开：M1 的标准档会把已完成轮次的过程折叠，工具卡不构建。
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    await _pumpChat(tester, store, backend);

    await tester.tap(_toolCard('call-bash', 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('BOOM'), findsOneWidget);

    await tester.tap(_toolCard('call-write', 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tool-diff-viewer')), findsOneWidget);
  });

  testWidgets('旧插件（无 toolCards 能力位）：全部回退通用卡（无专用折叠行）', (tester) async {
    final backend = _ToolsBackend(tools: const []);
    final store = AppStore()
      ..sessionId = 'session-tools'
      // 完全展开：M1 的标准档会把已完成轮次的过程折叠，工具卡不构建。
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    await _pumpChat(tester, store, backend);

    expect(find.text(r'$ ls -la'), findsNothing);
    expect(find.text('3 个匹配'), findsNothing);
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('grep'), findsOneWidget);
    // 展开仍是通用「参数/结果」块。
    await tester.tap(_toolCard('call-bash', 3));
    await tester.pumpAndSettle();
    expect(find.text('参数'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
  });

  testWidgets('R14：非命令工具即使结果摘要带终止字段也不显示退出码胶囊', (tester) async {
    final backend = _ToolsBackend(
      readResultSummary: {'exitCode': 3, 'signal': 'SIGTERM'},
    );
    final store = AppStore()
      ..sessionId = 'session-tools'
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    await _pumpChat(tester, store, backend);

    expect(find.text('exit 3'), findsNothing);
    expect(find.text('signal: SIGTERM'), findsNothing);
    // 同一列表里的命令卡仍显示自己的退出码。
    expect(find.text('exit 2'), findsOneWidget);
  });

  testWidgets('能力位逐工具生效：未声明的工具走通用卡', (tester) async {
    final backend = _ToolsBackend(tools: const ['read']);
    final store = AppStore()
      ..sessionId = 'session-tools'
      // 完全展开：M1 的标准档会把已完成轮次的过程折叠，工具卡不构建。
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    await _pumpChat(tester, store, backend);

    expect(find.text('src/b.ts · 行 2–5'), findsOneWidget);
    expect(find.text(r'$ ls -la'), findsNothing);
    expect(find.text('3 个匹配'), findsNothing);
  });

  testWidgets('write diff 截断时给明确提示而不是内联 diff', (tester) async {
    final backend = _ToolsBackend(writeDiffTruncated: true);
    final store = AppStore()
      ..sessionId = 'session-tools'
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    await _pumpChat(tester, store, backend);

    await tester.tap(_toolCard('call-write', 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tool-diff-viewer')), findsNothing);
    expect(find.textContaining('diff 较大'), findsOneWidget);
  });
}
