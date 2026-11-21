// issue #119：「任务清单已更新」事件卡不再单独显示（只保留任务面板 + 调试模式原始事件）。
//
// 验收点：
//   1. 普通模式时间线不出现该卡；任务清单面板仍随 todo/write 更新；
//   2. 调试模式仍能看到该卡（并保留原始事件入口：服务端 DETAIL_VISIBLE_TYPES 已含该类型）；
//   3. 历史回放与实时 SSE 同口径（两者都走 `_buildInto`，本文件用 /history 覆盖历史路径）；
//   4. 「复制整段对话」不得把普通模式隐藏的事件卡泄漏进剪贴板；
//   5. 既有 debugOnly 事件（session/jobs）行为不变。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue119_todo_card_visibility_test.dart

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/timeline.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-119';

class _Backend {
  _Backend(this.history);

  final List<Map<String, dynamic>> history;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue119.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
      unknownEvents: true,
      callCorrelation: true,
    );

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    final path = request.url.path;
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': history, 'hasMore': false};
    } else {
      body = {'ok': true};
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

/// 一轮会话：用户提问 + todo/write 事件 + 一条 debug-only 的 session/jobs 事件。
/// 两者走同一个 `_appendVisibleEvent` 路径，用后者验证既有 debugOnly 行为不变。
List<Map<String, dynamic>> _history() {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) => events.add({
        'seq': seq++,
        'type': type,
        'data': data,
        'time': 1000 + seq * 10,
      });
  add('turn/start', {'turn': 1});
  add('user/message', {
    'messageId': 'u1',
    'text': '开始任务',
    'sourceKind': 'user',
  });
  add('todo/write', {
    'turn': 1,
    'todos': [
      {'id': 't1', 'content': '只读核实', 'status': 'in_progress'},
      {'id': 't2', 'content': '汇报', 'status': 'pending'},
    ],
  });
  add('session/jobs', {
    'sessionId': _session,
    'jobs': [
      {'id': 'j1', 'label': '后台任务 A', 'status': 'running'},
    ],
  });
  add('assistant/message', {
    'turn': 1,
    'step': 2,
    'messageId': 'a1',
    'text': '我正在核对。',
  });
  return events;
}

Future<AppStore> _mount(
  WidgetTester tester, {
  required bool debug,
  List<Map<String, dynamic>>? history,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = WorkStepDisplayMode.expanded
    ..timelineDebug = debug;
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() async {
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: ChatScreen(
            key: ValueKey<String>('issue119-$debug'),
            store: store,
            apiClient: _Backend(history ?? _history()).api,
            onTitleChanged: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return store;
}

void _mockClipboard(WidgetTester tester, List<String> copied) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add('${(call.arguments as Map)['text']}');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

/// 通过对话操作栏复制整段（与 chat_copy_widget_test 同一入口）。
Future<String> _copyConversation(WidgetTester tester) async {
  await tester.tap(find.byTooltip('对话操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('复制当前已加载的对话'));
  await tester.pumpAndSettle();
  return 'copied';
}

void main() {
  group('#119 可见性：todo/write 进入调试专属清单', () {
    test('timelineTitleFor 仍有标题（调试卡继续使用）', () {
      expect(timelineTitleFor('todo/write'), '任务清单已更新');
    });

    test('todo/write 普通模式隐藏、调试模式可见（推翻 v3.1.4 时间线决策）', () {
      expect(debugOnlyTimelineTypes.contains('todo/write'), isTrue);
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'todo/write'), isFalse);
      expect(timelineTypeVisibleIn(TimelineMode.debug, 'todo/write'), isTrue);
    });

    test('既有 debugOnly 事件（session/jobs 等）行为不变', () {
      expect(debugOnlyTimelineTypes.contains('session/jobs'), isTrue);
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'session/jobs'),
          isFalse);
      expect(timelineTypeVisibleIn(TimelineMode.debug, 'session/jobs'), isTrue);
      for (final type in [
        'question/requested',
        'question/resolved',
        'approval/requested',
        'approval/resolved',
      ]) {
        expect(debugOnlyTimelineTypes.contains(type), isTrue, reason: type);
        expect(timelineTypeVisibleIn(TimelineMode.ordinary, type), isFalse,
            reason: type);
      }
    });

    test('真正未知的事件仍按事件保真契约可见（不误伤）', () {
      expect(timelineTypeVisibleIn(TimelineMode.ordinary, 'future/something-new'),
          isTrue);
    });
  });

  group('#119 渲染层：普通模式无卡，任务面板仍更新', () {
    testWidgets('普通模式：时间线不再出现「任务清单已更新」卡', (tester) async {
      await _mount(tester, debug: false);
      expect(find.textContaining('任务清单已更新'), findsNothing);
      expect(find.textContaining('后台任务状态'), findsNothing,
          reason: '既有 debugOnly 事件也不应回到普通模式');
    });

    testWidgets('普通模式：任务清单面板仍随 todo/write 更新（唯一展示入口）',
        (tester) async {
      await _mount(tester, debug: false);
      // 面板折叠态显示「任务」+「1 进行中 · 1 待处理」；数据来自同一条 todo/write。
      expect(find.text('任务'), findsOneWidget);
      expect(find.textContaining('1 进行中'), findsOneWidget);
      expect(find.textContaining('1 待处理'), findsOneWidget);
    });

    testWidgets('普通模式：对话正文不受影响（用户/助手消息仍在）', (tester) async {
      await _mount(tester, debug: false);
      expect(find.text('开始任务'), findsOneWidget);
      expect(find.textContaining('我正在核对。'), findsWidgets);
    });

    testWidgets('调试模式：同一张卡仍可见（可审阅，不破坏排障）', (tester) async {
      await _mount(tester, debug: true);
      expect(find.textContaining('任务清单已更新'), findsOneWidget);
    });
  });

  group('#119 实时 SSE：与历史回放同口径', () {
    testWidgets('实时 todo/write：普通模式不出卡，任务面板即时更新', (tester) async {
      final store = await _mount(tester, debug: false, history: const []);
      // 运行中一轮 + 一条 todo/write 实时事件（与 _handleEvent 的 SSE 路径同形）。
      store.injectFrame({
        'type': 'session/event',
        'sessionId': _session,
        'event': {
          'seq': 1,
          'type': 'turn/start',
          'data': {'turn': 1},
          'time': 1010,
        },
      });
      store.injectFrame({
        'type': 'session/event',
        'sessionId': _session,
        'event': {
          'seq': 2,
          'type': 'todo/write',
          'data': {
            'turn': 1,
            'todos': [
              {'id': 't1', 'content': '实时任务', 'status': 'in_progress'},
            ],
          },
          'time': 1020,
        },
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('任务清单已更新'), findsNothing,
          reason: '实时路径同样不得生成独立卡');
      expect(find.textContaining('1 进行中'), findsOneWidget,
          reason: '任务面板必须仍随实时 todo/write 更新');
      // 注入 session/event 会触发 800ms 会话列表去抖 Timer；跑完再结束用例。
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('实时 todo/write：调试模式仍出卡', (tester) async {
      final store = await _mount(tester, debug: true, history: const []);
      store.injectFrame({
        'type': 'session/event',
        'sessionId': _session,
        'event': {
          'seq': 1,
          'type': 'todo/write',
          'data': {'turn': 1, 'todos': const []},
          'time': 1010,
        },
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('任务清单已更新'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('#119 复制整段：隐藏卡不得泄漏进剪贴板', () {
    testWidgets('普通模式复制：不含「任务清单已更新」，含对话正文', (tester) async {
      final copied = <String>[];
      _mockClipboard(tester, copied);
      await _mount(tester, debug: false);
      await _copyConversation(tester);
      expect(copied, hasLength(1));
      expect(copied.single, isNot(contains('任务清单已更新')));
      expect(copied.single, isNot(contains('后台任务状态')));
      expect(copied.single, contains('你：开始任务'));
      expect(copied.single, contains('助手：我正在核对。'));
    });

    testWidgets('调试模式复制：包含调试事件（与调试视图口径一致）', (tester) async {
      final copied = <String>[];
      _mockClipboard(tester, copied);
      await _mount(tester, debug: true);
      await _copyConversation(tester);
      expect(copied, hasLength(1));
      expect(copied.single, contains('任务清单已更新'));
      expect(copied.single, contains('你：开始任务'));
    });
  });
}
