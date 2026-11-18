// issue #120：ask_user_question 在手机端不弹出（只显示工具行）。
//
// 本文件只做**只读定位**：验证 App 侧三种可能
//   (a) 问询属于别的会话（父会话/子代理）→ questionForSession(_mySessionId) 查不到；
//   (b) SSE 帧 sessionId 与当前页不匹配 → _handleEvent 过滤掉；
//   (c) 状态拿到了但只有工具行入口、没有自动问询卡。
// 不修改产品代码。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue120_question_entry_test.dart

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/logger.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-120';
const _otherSession = 'session-120-parent';

class _Backend {
  _Backend(this.history);

  final List<Map<String, dynamic>> history;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue120.test'
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
    ..toolCardsCapabilities = const ToolCardsCapabilities(
      version: 1,
      tools: {'ask_user_question'},
    );

  Future<http.Response> _handle(http.Request request) async {
    Map<String, dynamic> body;
    final path = request.url.path;
    if (path == '/m/api/history') {
      final params = request.url.queryParameters;
      if (params.containsKey('before') || params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else {
        body = {'ok': true, 'events': history, 'hasMore': false};
      }
    } else if (path == '/m/api/event-detail') {
      body = {'ok': true, 'event': null};
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

/// 运行中的一轮：用户提问 + 一次 ask_user_question 工具调用/结果。
/// 工具行是手机截图里唯一可见的东西，本夹具保证它真实渲染。
List<Map<String, dynamic>> _askHistory() {
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
    'text': '发布前先确认一下',
    'sourceKind': 'user',
  });
  add('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'call-ask',
    'name': 'ask_user_question',
    'arguments': '{"questions":[{"id":"q1","question":"要发布吗？"}]}',
    // 服务端投影（tool_cards 卡片的折叠行/待答入口都读它）
    'summary': {
      'kind': 'question',
      'tool': 'ask_user_question',
      'questions': [
        {
          'id': 'q1',
          'header': '确认',
          'question': '要发布吗？',
          'options': [
            {'label': '发布'},
            {'label': '稍后'},
          ],
        },
      ],
    },
  });
  return events;
}

Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.expanded,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode;
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
            key: const ValueKey<String>('issue120'),
            store: store,
            apiClient: backend.api,
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

/// 真实 SSE `mobile/frame` 形状：`{type:'mobile/frame', frame:{type:'question/requested', ...}}`。
void _injectQuestion(
  AppStore store, {
  required String sessionId,
  String rpcId = 'session-120:q1',
  String question = '要发布吗？',
}) {
  store.injectFrame({
    'type': 'mobile/frame',
    'frame': {
      'type': 'question/requested',
      'rpcId': rpcId,
      'sessionId': sessionId,
      'questionId': rpcId,
      'questions': [
        {
          'id': 'q1',
          'header': '确认',
          'question': question,
          'options': [
            {'label': '发布'},
            {'label': '稍后'},
          ],
        },
      ],
    },
  });
}

void main() {
  setUp(() async {
    await AppLog.instance.clear();
  });

  testWidgets(
      '现状 (c) 证伪：当前会话的 pending 问询在 mobile/frame 到达后**自动**渲染问询卡',
      (tester) async {
    final store = await _mount(tester, _Backend(_askHistory()));
    _injectQuestion(store, sessionId: _session);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      store.questionForSession(_session),
      isNotNull,
      reason: 'mobile/frame 到达后 store 必须按 sessionId 挂上 pending',
    );
    // 问询卡自身按 rpcId 挂 key（chat_screen.dart:5910），据此定位避免与工具卡内容混淆。
    final card = find.byKey(const ValueKey<String>('session-120:q1'));
    expect(card, findsOneWidget, reason: '问询卡应自动出现（不需要用户先点工具行）');
    expect(
      find.descendant(of: card, matching: find.text('要发布吗？')),
      findsOneWidget,
    );
    // 工具行入口也在（同一 pending 通道）。
    expect(find.byKey(const Key('open-question:call-ask')), findsOneWidget);
  });

  testWidgets(
      '现状 (a)：问询属于**另一个会话**（父/子代理）时 → 当前页无卡、无工具行入口',
      (tester) async {
    final store = await _mount(tester, _Backend(_askHistory()));
    _injectQuestion(store, sessionId: _otherSession);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      store.questionForSession(_session),
      isNull,
      reason: '问询按 sessionId 归属，别的会话的 pending 查不到',
    );
    expect(
      store.questionForSession(_otherSession),
      isNotNull,
      reason: '问询确实挂在另一个会话下（store 收到了，只是当前页不认）',
    );
    expect(
      find.byKey(const ValueKey<String>('session-120:q1')),
      findsNothing,
      reason: '当前页不应显示别的会话的问询卡',
    );
    expect(
      find.byKey(const Key('open-question:call-ask')),
      findsNothing,
      reason:
          '工具行入口也按当前会话的 pending 判定 → 无入口。这与截图「只有工具行」一致',
    );
  });

  testWidgets('现状：先有 pending、后进会话（initState 路径）仍自动显示',
      (tester) async {
    final store = AppStore()
      ..sessionId = _session
      ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
      ..stepDisplayMode = WorkStepDisplayMode.expanded;
    // 进入页面前 store 已有该会话 pending（断线重连补发场景）。
    _injectQuestion(store, sessionId: _session);
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
              key: const ValueKey<String>('issue120-late'),
              store: store,
              apiClient: _Backend(_askHistory()).api,
              onTitleChanged: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey<String>('session-120:q1'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('要发布吗？')),
      findsOneWidget,
    );
  });

  testWidgets('#120 观测：真机定位日志覆盖 帧归属 / 本页绑定 / store 会话 / 匹配结果',
      (tester) async {
    final store = await _mount(tester, _Backend(_askHistory()));
    _injectQuestion(store, sessionId: _session);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final lines = AppLog.instance.lines.where((l) => l.contains('[120-debug]')).toList();
    final frameLog = lines.firstWhere(
      (l) => l.contains('question frame:'),
      orElse: () => '',
    );
    expect(frameLog, isNotEmpty, reason: '当前会话命中时必须记录 frame 日志：$lines');
    expect(frameLog, contains('frameSessionId=$_session'));
    expect(frameLog, contains('mySessionId=$_session'));
    expect(frameLog, contains('storeSessionId=$_session'));
    expect(frameLog, contains('matched=true'));
    final storeLog = lines.firstWhere(
      (l) => l.contains('question pending stored:'),
      orElse: () => '',
    );
    expect(storeLog, contains('sessionId=$_session'),
        reason: 'store 侧必须记录问询实际挂到哪个 session：$lines');
    // 结算路径同样留痕。
    store.injectFrame({
      'type': 'mobile/frame',
      'frame': {
        'type': 'question/resolved',
        'questionRpcId': 'session-120:q1',
        'sessionId': _session,
      },
    });
    await tester.pump();
    final resolvedLog = AppLog.instance.lines.firstWhere(
      (l) => l.contains('question resolved:'),
      orElse: () => '',
    );
    expect(resolvedLog, isNotEmpty, reason: 'resolved 分支必须留痕：$lines');
    expect(resolvedLog, contains('matched=true'));
  });

  testWidgets('#120 观测：问询属于别的会话时，页面过滤日志写明 frame/my 会话不一致',
      (tester) async {
    final store = await _mount(tester, _Backend(_askHistory()));
    _injectQuestion(store, sessionId: _otherSession);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final dropped = AppLog.instance.lines.firstWhere(
      (l) => l.contains('question/requested dropped by page filter:'),
      orElse: () => '',
    );
    expect(dropped, isNotEmpty, reason: '跨会话帧被过滤时必须留痕：${AppLog.instance.lines}');
    expect(dropped, contains('frameSessionId=$_otherSession'));
    expect(dropped, contains('mySessionId=$_session'));
    expect(dropped, contains('storeSessionId=$_session'));
    // store 侧仍然记录：问询真实挂到了另一个会话。
    final storeLog = AppLog.instance.lines.firstWhere(
      (l) => l.contains('question pending stored:'),
      orElse: () => '',
    );
    expect(storeLog, contains('sessionId=$_otherSession'));
  });

  test('store 语义：questionForSession 按 sessionId 精确归属，legacy 字段只在同会话兜底', () {
    final store = AppStore();
    _injectQuestion(store, sessionId: _otherSession);
    expect(store.questionForSession(_session), isNull);
    expect(store.questionForSession(_otherSession), isNotNull);
    // legacy 单 pending 字段（旧服务端/旧调用）也必须按 sessionId 兜底。
    store.pendingQuestion = QuestionRequest(
      rpcId: 'legacy',
      sessionId: _session,
      questions: [AskQuestion(id: 'q', question: '旧通道问询')],
    );
    expect(store.questionForSession(_session)?.rpcId, 'legacy');
    expect(
      store.questionForSession(_otherSession)?.rpcId,
      isNot('legacy'),
      reason: 'legacy 字段不得跨会话串台（另一会话自己的 pending 仍应可查）',
    );
  });
}
