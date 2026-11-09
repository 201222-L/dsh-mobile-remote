// issue #54（M3 Batch 1）：对话页专用工具卡（折叠行/退出码/命中数/diff/通用降级/能力位）。
// issue #66（M3 Batch 2-A）：todo_write / ask_user_question / skill 折叠行与只读展开、待答入口。

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

/// issue #66：Batch 1 + Batch 2-A 共 13 个可投影工具（能力位顺序与服务端一致）。
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
  'todo_write',
  'ask_user_question',
  'skill',
];

/// 旧服务端能力位：只声明 Batch 1 的 10 个工具。
const _batch1Tools = [
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
    this.todoEmpty = false,
    this.questionAnswered = true,
    this.skillEmpty = false,
  }) : tools = tools ?? _allTools;

  final List<String> tools;
  final bool writeDiffTruncated;

  /// 模拟旧服务端/异常数据：read 结果竟带 exitCode，App 必须按 call kind 忽略。
  final Map<String, dynamic>? readResultSummary;

  /// issue #66 空态开关：todo 0 项 / question 结果无 answers / skill 无结果文本。
  final bool todoEmpty;
  final bool questionAnswered;
  final bool skillEmpty;

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

  Map<String, dynamic> get _todoSummary => {
    'kind': 'todo',
    'tool': 'todo_write',
    'items': todoEmpty
        ? <Object>[]
        : <Object>[
            {'content': '写文档', 'status': 'completed'},
            {'content': '跑测试', 'status': 'in_progress'},
            {'content': '发 PR', 'status': 'pending'},
          ],
    'counts': todoEmpty
        ? {'pending': 0, 'inProgress': 0, 'completed': 0}
        : {'pending': 1, 'inProgress': 1, 'completed': 1},
  };

  Map<String, dynamic> get _questionSummary => {
    'kind': 'question',
    'tool': 'ask_user_question',
    'questions': <Object>[
      {
        'id': 'q1',
        'header': '确认',
        'question': '要发布吗？',
        'options': <Object>[
          {'label': '发布', 'description': '立即发布'},
          {'label': '稍后'},
        ],
        'multiSelect': false,
      },
      {'id': 'q2', 'question': '备注？'},
    ],
  };

  List<Map<String, dynamic>> get _events => [
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
        if (readResultSummary != null) ..._summary(readResultSummary!),
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
    // issue #66：Batch 2-A 三张专用卡（todo/question/skill）。
    {
      'seq': 13,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-todo',
        'name': 'todo_write',
        'arguments': '{"todos":[]}',
        ..._summary(_todoSummary),
      },
    },
    {
      'seq': 14,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-todo',
        'name': 'todo_write',
        'text': 'Todos updated',
        'isError': false,
      },
    },
    {
      'seq': 15,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-ask',
        'name': 'ask_user_question',
        'arguments': '{"questions":[]}',
        ..._summary(_questionSummary),
      },
    },
    {
      'seq': 16,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-ask',
        'name': 'ask_user_question',
        'text': '{"answers":[{"id":"q1","selected":["发布"]}]}',
        'isError': false,
        if (questionAnswered)
          ..._summary({
            'answers': <Object>[
              {
                'questionId': 'q1',
                'values': ['发布'],
              },
              {'questionId': 'q2', 'values': <Object>[]},
            ],
          }),
      },
    },
    {
      'seq': 17,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-skill',
        'name': 'skill',
        'arguments': '{"name":"guizang-ppt-skill"}',
        ..._summary({
          'kind': 'skill',
          'tool': 'skill',
          'name': 'guizang-ppt-skill',
        }),
      },
    },
    {
      'seq': 18,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-skill',
        'name': 'skill',
        'text': skillEmpty ? '' : '已加载 skill：guizang-ppt-skill',
        'isError': false,
      },
    },
    {
      'seq': 19,
      'type': 'turn/end',
      'data': {
        'turn': 1,
        'reason': {'kind': 'completed'},
      },
    },
  ];

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      return _json({
        'ok': true,
        'hasMore': false,
        'turnTails': const <String, dynamic>{},
        'events': _events,
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
  // 历史夹具含 9 张工具卡：拉高测试视口，避免 SliverList 懒构建导致卡片未创建。
  tester.view.physicalSize = const Size(900, 5000);
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

/// 展开一张工具卡（视口很高，但仍先确保可点区域可见再点，避免滚动/懒构建误差）。
/// 明确点标题区（左上角内侧）而不是卡片几何中心：折叠行出现「打开问询」入口后卡片
/// 变高，几何中心可能落到折叠行上而点不开。
Future<void> _expandCard(WidgetTester tester, Finder card) async {
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getTopLeft(card) + const Offset(12, 12));
  await tester.pumpAndSettle();
}

AppStore _store() => AppStore()
  ..sessionId = 'session-tools'
  // 完全展开：M1 的标准档会把已完成轮次的过程折叠，工具卡不构建。
  ..stepDisplayMode = WorkStepDisplayMode.expanded;

void main() {
  testWidgets('专用卡折叠行：命令/退出码/文件统计/搜索命中数，未知工具回退', (tester) async {
    final backend = _ToolsBackend();
    final store = _store();
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

  testWidgets('issue #66 折叠行：N 项任务 · M 完成 / N 个问题 / skill · name', (tester) async {
    final backend = _ToolsBackend();
    final store = _store();
    await _pumpChat(tester, store, backend);

    expect(find.text('3 项任务 · 1 完成'), findsOneWidget);
    expect(find.text('2 个问题'), findsOneWidget);
    expect(find.text('skill · guizang-ppt-skill'), findsOneWidget);
  });

  testWidgets('展开：command 显示终端输出，write 内联统一 diff', (tester) async {
    final backend = _ToolsBackend();
    final store = _store();
    await _pumpChat(tester, store, backend);

    await tester.tap(_toolCard('call-bash', 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('BOOM'), findsOneWidget);

    await tester.tap(_toolCard('call-write', 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tool-diff-viewer')), findsOneWidget);
  });

  testWidgets('issue #66 展开：todo 只读清单 / question 只读问答 / skill 只读说明', (tester) async {
    final backend = _ToolsBackend();
    final store = _store();
    await _pumpChat(tester, store, backend);

    // todo：只读清单，状态图标而非可交互勾选框。
    final todoCard = _toolCard('call-todo', 13);
    await _expandCard(tester, todoCard);
    expect(find.descendant(of: todoCard, matching: find.text('写文档')), findsOneWidget);
    expect(find.descendant(of: todoCard, matching: find.text('跑测试')), findsOneWidget);
    expect(find.descendant(of: todoCard, matching: find.text('发 PR')), findsOneWidget);
    expect(
      find.descendant(of: todoCard, matching: find.byIcon(Icons.check_circle)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: todoCard,
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: todoCard,
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: todoCard, matching: find.byType(Checkbox)),
      findsNothing,
      reason: '只读：不能出现可交互勾选框',
    );

    // question：只读问题/选项/答案，行内无任何作答控件。
    final askCard = _toolCard('call-ask', 15);
    await _expandCard(tester, askCard);
    expect(find.descendant(of: askCard, matching: find.text('确认')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('要发布吗？')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('发布')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('稍后')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('立即发布')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('答案：发布')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('未回答')), findsOneWidget);
    final id = 'tool-question-answer:q1';
    expect(find.byKey(ValueKey<String>(id)), findsOneWidget);
    expect(
      find.descendant(of: askCard, matching: find.byType(TextField)),
      findsNothing,
      reason: '只读：问询卡展开态不得有任何输入框',
    );
    expect(
      find.descendant(of: askCard, matching: find.byType(TextButton)),
      findsNothing,
      reason: '只读：作答入口只能在行尾（且仅待答时）',
    );

    // skill：只读说明块。
    final skillCard = _toolCard('call-skill', 17);
    await _expandCard(tester, skillCard);
    expect(find.descendant(of: skillCard, matching: find.text('说明')), findsOneWidget);
    expect(find.textContaining('已加载 skill'), findsOneWidget);
    expect(
      find.descendant(of: skillCard, matching: find.byType(TextButton)),
      findsNothing,
    );
  });

  testWidgets('旧插件（无 toolCards 能力位）：全部回退通用卡（无专用折叠行）', (tester) async {
    final backend = _ToolsBackend(tools: const []);
    final store = _store();
    await _pumpChat(tester, store, backend);

    expect(find.text(r'$ ls -la'), findsNothing);
    expect(find.text('3 个匹配'), findsNothing);
    expect(find.text('3 项任务 · 1 完成'), findsNothing);
    expect(find.text('2 个问题'), findsNothing);
    expect(find.text('skill · guizang-ppt-skill'), findsNothing);
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('grep'), findsOneWidget);
    // 展开仍是通用「参数/结果」块。
    await tester.tap(_toolCard('call-bash', 3));
    await tester.pumpAndSettle();
    expect(find.text('参数'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
  });

  testWidgets('旧服务端（仅 10 工具能力位）：新三工具走通用卡，旧工具仍专用', (tester) async {
    final backend = _ToolsBackend(tools: _batch1Tools);
    final store = _store();
    await _pumpChat(tester, store, backend);

    // Batch 1 工具仍专用。
    expect(find.text(r'$ ls -la'), findsOneWidget);
    expect(find.text('3 个匹配'), findsOneWidget);
    // Batch 2-A 三工具回退通用卡（无专用折叠行）。
    expect(find.text('3 项任务 · 1 完成'), findsNothing);
    expect(find.text('2 个问题'), findsNothing);
    expect(find.text('skill · guizang-ppt-skill'), findsNothing);
    await tester.tap(_toolCard('call-todo', 13));
    await tester.pumpAndSettle();
    expect(find.text('参数'), findsOneWidget);
    expect(find.text('结果'), findsOneWidget);
  });

  testWidgets('R14：非命令工具即使结果摘要带终止字段也不显示退出码胶囊', (tester) async {
    final backend = _ToolsBackend(
      readResultSummary: {'exitCode': 3, 'signal': 'SIGTERM'},
    );
    final store = _store();
    await _pumpChat(tester, store, backend);

    expect(find.text('exit 3'), findsNothing);
    expect(find.text('signal: SIGTERM'), findsNothing);
    // 同一列表里的命令卡仍显示自己的退出码。
    expect(find.text('exit 2'), findsOneWidget);
  });

  testWidgets('能力位逐工具生效：未声明的工具走通用卡', (tester) async {
    final backend = _ToolsBackend(tools: const ['read']);
    final store = _store();
    await _pumpChat(tester, store, backend);

    expect(find.text('src/b.ts · 行 2–5'), findsOneWidget);
    expect(find.text(r'$ ls -la'), findsNothing);
    expect(find.text('3 个匹配'), findsNothing);
  });

  testWidgets('write diff 截断时给明确提示而不是内联 diff', (tester) async {
    final backend = _ToolsBackend(writeDiffTruncated: true);
    final store = _store();
    await _pumpChat(tester, store, backend);

    await tester.tap(_toolCard('call-write', 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tool-diff-viewer')), findsNothing);
    expect(find.textContaining('diff 较大'), findsOneWidget);
  });

  testWidgets('issue #66 待答入口：pending id 命中才出现，点击打开复用问询卡的弹层', (tester) async {
    final backend = _ToolsBackend();
    final store = _store();
    store.pendingQuestion = QuestionRequest(
      rpcId: 'rpc-q1',
      sessionId: 'session-tools',
      questions: [
        AskQuestion(
          id: 'q1',
          header: '确认',
          question: '要发布吗？',
          options: [
            AskOption(label: '发布', description: '立即发布'),
            AskOption(label: '稍后'),
          ],
        ),
      ],
    );
    await _pumpChat(tester, store, backend);

    final entry = find.byKey(const Key('open-question:call-ask'));
    expect(entry, findsOneWidget, reason: 'summary 的 q1 命中 pending → 行尾入口出现');
    expect(find.text('打开问询'), findsOneWidget);
    // 非问询卡没有入口。
    expect(find.byKey(const Key('open-question:call-bash')), findsNothing);
    expect(find.byKey(const Key('open-question:call-todo')), findsNothing);

    await tester.ensureVisible(entry);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    final sheet = find.byKey(const ValueKey<String>('question-sheet:rpc-q1'));
    expect(sheet, findsOneWidget, reason: '点击入口应弹出复用现有 _QuestionCard 的弹层');
    expect(
      find.descendant(of: sheet, matching: find.text('要发布吗？')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('提交')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.byType(TextField)),
      findsOneWidget,
      reason: '弹层内是既有问询卡（可作答）',
    );
  });

  testWidgets('issue #66 待答入口：pending id 与 summary id 不匹配 → 入口不出现', (tester) async {
    final backend = _ToolsBackend();
    final store = _store();
    // R1：App 不得 trim id——带空白的 pending id 与 summary 的 'q1' 精确比较即不匹配。
    store.pendingQuestion = QuestionRequest(
      rpcId: 'rpc-other',
      sessionId: 'session-tools',
      questions: [AskQuestion(id: ' q1 ', question: '别的问询')],
    );
    await _pumpChat(tester, store, backend);

    expect(find.byKey(const Key('open-question:call-ask')), findsNothing);
    expect(find.text('打开问询'), findsNothing);
  });

  testWidgets('issue #66 仍待答且结果无答案 → 展开态不显示答案行（入口在行尾）', (tester) async {
    final backend = _ToolsBackend(questionAnswered: false);
    final store = _store();
    store.pendingQuestion = QuestionRequest(
      rpcId: 'rpc-q1',
      sessionId: 'session-tools',
      questions: [AskQuestion(id: 'q1', question: '要发布吗？')],
    );
    await _pumpChat(tester, store, backend);

    final askCard = _toolCard('call-ask', 15);
    await _expandCard(tester, askCard);
    expect(find.descendant(of: askCard, matching: find.text('要发布吗？')), findsOneWidget);
    expect(find.descendant(of: askCard, matching: find.text('未回答')), findsNothing);
    expect(find.text('答案：发布'), findsNothing);
    // 作答入口仍在行尾（行内无作答控件）。
    expect(find.byKey(const Key('open-question:call-ask')), findsOneWidget);
    expect(
      find.descendant(of: askCard, matching: find.byType(TextField)),
      findsNothing,
    );
  });

  testWidgets('issue #66 空态：todo 0 项 / question 未答 / skill 无说明', (tester) async {
    final backend = _ToolsBackend(
      todoEmpty: true,
      questionAnswered: false,
      skillEmpty: true,
    );
    final store = _store();
    await _pumpChat(tester, store, backend);

    expect(find.text('0 项任务 · 0 完成'), findsOneWidget);
    final todoCard = _toolCard('call-todo', 13);
    await _expandCard(tester, todoCard);
    expect(find.descendant(of: todoCard, matching: find.text('无任务')), findsOneWidget);

    final askCard = _toolCard('call-ask', 15);
    await _expandCard(tester, askCard);
    expect(
      find.descendant(of: askCard, matching: find.text('未回答')),
      findsNWidgets(2),
      reason: '结果里没有答案且问询已结束 → 每题都显示未回答',
    );
    expect(
      find.descendant(of: askCard, matching: find.byType(TextField)),
      findsNothing,
    );

    final skillCard = _toolCard('call-skill', 17);
    await _expandCard(tester, skillCard);
    expect(find.descendant(of: skillCard, matching: find.text('无说明')), findsOneWidget);
  });
}
