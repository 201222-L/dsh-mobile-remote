// issue #99：compaction surface replace replay（sourceEventSeqs + surfaceOp=replace）
// 必须按替换语义消费：不新增工具行、旧 shadowed 事件不显示、replay 不生成历史工具卡。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/timeline.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _callId = 'call_00_mx03kxx6nhrcr2xruau1vg9u';

ChatEvent _event(
  int seq,
  String type,
  Map<String, dynamic> data, {
  List<int>? sourceEventSeqs,
  Map<String, dynamic>? surfaceOp,
}) => ChatEvent(
  seq: seq,
  type: type,
  data: data,
  sourceEventSeqs: sourceEventSeqs ?? const [],
  surfaceOp: SurfaceOp.fromJson(surfaceOp),
);

Map<String, dynamic> _replayJson() => {
  'seq': 13283,
  'type': 'tool/result',
  'time': 1794490887536,
  'data': {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'text': 'note 2312'},
  'sourceEventSeqs': [9142],
  'surfaceOp': {'op': 'replace', 'startSeq': 9142, 'endSeq': 9142},
};

Finder _toolCard(String callId) => find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('tool:$callId:'),
    );

void main() {
  test('issue #99：ChatEvent 解析 surfaceOp/sourceEventSeqs（history/SSE 同一摘要）', () {
    final event = ChatEvent.fromJson(_replayJson());
    expect(event.isSurfaceReplace, isTrue);
    expect(event.surfaceAnchorSeq, 9142);
    expect(event.sourceEventSeqs, [9142]);
    expect(event.surfaceOp?.op, 'replace');
    expect(event.surfaceOp?.startSeq, 9142);
    expect(event.data?['callId'], _callId);
    // 旧 App 兼容：无字段时默认空/非 replace。
    final plain = ChatEvent.fromJson({'seq': 1, 'type': 'tool/result', 'data': {}});
    expect(plain.isSurfaceReplace, isFalse);
    expect(plain.sourceEventSeqs, isEmpty);
    expect(plain.surfaceAnchorSeq, 1);
  });

  test('issue #99 P2：App 严格解析——坏 envelope 不解释为 replace（与 server 同口径）', () {
    for (final bad in <Map<String, dynamic>>[
      {'surfaceOp': {'op': 'replace', 'startSeq': null, 'endSeq': 1}},
      {'surfaceOp': {'op': 'replace', 'startSeq': false, 'endSeq': 1}},
      {'surfaceOp': {'op': 'replace', 'startSeq': '', 'endSeq': 1}},
      {'surfaceOp': {'op': 'replace', 'startSeq': true, 'endSeq': 1}},
      {'surfaceOp': {'op': 'replace', 'startSeq': '9142', 'endSeq': 9142}},
      {'surfaceOp': {'op': 'replace', 'startSeq': -1, 'endSeq': 1}},
      {'surfaceOp': {'op': 'replace', 'startSeq': 5, 'endSeq': 1}},
      {'sourceEventSeqs': [null]},
      {'sourceEventSeqs': [false]},
      {'sourceEventSeqs': ['9142']},
      {'sourceEventSeqs': [-1]},
      {'sourceEventSeqs': [9142]}, // >= 当前 seq
    ]) {
      final event = ChatEvent.fromJson({
        'seq': 13283,
        'type': 'tool/result',
        'data': {'turn': 148},
        ...bad,
      });
      expect(event.isSurfaceReplace, isFalse, reason: '$bad');
      expect(event.surfaceOp, isNull, reason: '$bad');
    }
    // 合法 source 去重/正序；严格小于当前 seq。
    final ok = ChatEvent.fromJson({
      'seq': 13283,
      'type': 'tool/result',
      'data': {},
      'sourceEventSeqs': [9142, 2, 9142, 3],
      'surfaceOp': {'op': 'replace', 'startSeq': 2, 'endSeq': 9142},
    });
    expect(ok.sourceEventSeqs, [2, 3, 9142]);
  });

  test('issue #99 P2：surfaceOp union——真实字符串 append 不触发 shadow 且保留 source', () {
    final append = ChatEvent.fromJson({
      'seq': 10,
      'type': 'tool/result',
      'data': {'turn': 220, 'step': 1, 'callId': 'c-append', 'name': 'bash', 'text': 'ok'},
      'surfaceOp': 'append',
      'sourceEventSeqs': [3],
    });
    expect(append.surfaceOp?.op, 'append');
    expect(append.surfaceOp?.startSeq, isNull);
    expect(append.isSurfaceReplace, isFalse);
    expect(append.sourceEventSeqs, [3]);

    final reducer = TimelineReducer();
    reducer.apply(append);
    expect(reducer.isShadowedSeq(3), isFalse, reason: 'append 不得遮蔽 source');
    reducer.apply(_event(3, 'tool/result', {'turn': 220, 'step': 1, 'callId': 'c-old', 'name': 'bash', 'text': 'old'}));
    expect(reducer.isShadowedSeq(3), isFalse);

    // 对象 append：可省略 start/end；带则保留。
    final objectAppend = ChatEvent.fromJson({
      'seq': 20,
      'type': 'tool/result',
      'data': {},
      'surfaceOp': {'op': 'append'},
      'sourceEventSeqs': [3],
    });
    expect(objectAppend.surfaceOp?.op, 'append');
    expect(objectAppend.sourceEventSeqs, [3]);
  });

  test('issue #99 P2：envelope 原子解析——缺失≠显式 null，任一非法整组丢弃', () {
    ChatEvent parse(Map<String, dynamic> extra) => ChatEvent.fromJson({
      'seq': 10,
      'type': 'tool/result',
      'data': {},
      ...extra,
    });

    // 真实 append + 非法 source（>=seq）→ 整个 envelope 丢弃。
    var event = parse({'surfaceOp': 'append', 'sourceEventSeqs': [3, 10]});
    expect(event.surfaceOp, isNull);
    expect(event.sourceEventSeqs, isEmpty);
    expect(event.isSurfaceReplace, isFalse);

    // 显式 null 与缺失不同：显式 null 一律非法。
    for (final extra in <Map<String, dynamic>>[
      {'surfaceOp': null},
      {'sourceEventSeqs': null},
      {'surfaceOp': 'append', 'sourceEventSeqs': null},
      {'surfaceOp': {'op': 'append', 'startSeq': null, 'endSeq': null}},
      {'surfaceOp': {'op': 'append', 'startSeq': null}},
    ]) {
      event = parse(extra);
      expect(event.surfaceOp, isNull, reason: '$extra');
      expect(event.sourceEventSeqs, isEmpty, reason: '$extra');
    }

    // 两字段都缺失 → 正常非 surface 事件。
    event = parse({});
    expect(event.surfaceOp, isNull);
    expect(event.sourceEventSeqs, isEmpty);

    // 仅 source（无 surfaceOp 键）合法；缺失 surfaceOp 不等于非法。
    event = parse({'sourceEventSeqs': [3]});
    expect(event.surfaceOp, isNull);
    expect(event.sourceEventSeqs, [3]);

    // 合法 append 无 source / 合法对象 append / replace + 合法 source。
    event = parse({'surfaceOp': 'append'});
    expect(event.surfaceOp?.op, 'append');
    expect(event.sourceEventSeqs, isEmpty);
    event = parse({'surfaceOp': {'op': 'append'}, 'sourceEventSeqs': [3]});
    expect(event.surfaceOp?.op, 'append');
    expect(event.sourceEventSeqs, [3]);
    event = parse({
      'surfaceOp': {'op': 'replace', 'startSeq': 3, 'endSeq': 3},
      'sourceEventSeqs': [3],
    });
    expect(event.isSurfaceReplace, isTrue);
    expect(event.sourceEventSeqs, [3]);

    // replace + 坏 source（混合）→ 整个 envelope 丢弃，不能留下 replace。
    event = parse({
      'surfaceOp': {'op': 'replace', 'startSeq': 3, 'endSeq': 3},
      'sourceEventSeqs': [3, 10],
    });
    expect(event.surfaceOp, isNull);
    expect(event.sourceEventSeqs, isEmpty);
    expect(event.isSurfaceReplace, isFalse);
  });

  test('issue #99 P2：surfaceOp union 非法值矩阵（字符串/对象 append/对象 replace）', () {
    for (final surfaceOp in <Object?>[
      'replace', 'APPEND', '', 'append ', true, false, null, 1, [], ['append'],
      {'op': 'append', 'startSeq': 3},
      {'op': 'append', 'endSeq': 3},
      {'op': 'append', 'startSeq': 9, 'endSeq': 3},
      {'op': 'append', 'startSeq': null, 'endSeq': 3},
      {'op': 'append', 'startSeq': '3', 'endSeq': '4'},
      {'op': 'other', 'startSeq': 3, 'endSeq': 3},
      {'op': 'replace', 'startSeq': 1},
    ]) {
      final event = ChatEvent.fromJson({
        'seq': 10,
        'type': 'tool/result',
        'data': {},
        'surfaceOp': surfaceOp,
        'sourceEventSeqs': [3],
      });
      expect(event.surfaceOp, isNull, reason: '${surfaceOp}');
      expect(event.sourceEventSeqs, isEmpty, reason: '坏 surfaceOp 时 source 也不得解释');
    }
  });

  test('issue #99：原 9142 + replace 13283 合并为同一工具行，不追加 replay 行', () {
    final reducer = TimelineReducer();
    reducer.apply(_event(9139, 'tool/call', {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'arguments': 'ls'}));
    reducer.apply(_event(9142, 'tool/result', {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'text': 'old'}));
    reducer.apply(ChatEvent.fromJson(_replayJson()));
    final toolItems = reducer.items.where((item) => item.kind == TimelineItemKind.tool).toList();
    expect(toolItems, hasLength(1), reason: 'surface replace 不得新增工具行');
    expect(toolItems.single.seq, 9139, reason: '工具行仍锚定原调用位置');
    expect(reducer.tools[_callId]?.result, contains('note 2312'), reason: '替换内容覆盖原结果');
    expect(reducer.tools.length, 1);
  });

  test('issue #99：只有 replay 时按 source seq 记录、不生成任何工具行（历史卡不出现）', () {
    final reducer = TimelineReducer();
    reducer.apply(ChatEvent.fromJson(_replayJson()));
    expect(reducer.items.where((item) => item.kind == TimelineItemKind.tool), isEmpty);
    expect(reducer.tools[_callId]?.seq, 9142, reason: 'replay-only 锚点回落到 source seq');
  });

  test('issue #99：晚到的旧 shadowed seq 不再显示', () {
    final reducer = TimelineReducer();
    reducer.apply(_event(1, 'turn/start', {'turn': 220}));
    reducer.apply(ChatEvent.fromJson(_replayJson()));
    reducer.apply(_event(9142, 'tool/result', {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'text': 'old'}));
    expect(reducer.items.where((item) => item.kind == TimelineItemKind.tool), isEmpty);
    // 原事件已在 replace 时记录替代内容，晚到旧内容不得覆盖。
    expect(reducer.tools[_callId]?.result, contains('note 2312'));
  });

  test('issue #99：tracker 不把 replay-only 工具生成历史过程组', () {
    final tracker = TurnProcessTracker();
    tracker.observe(_event(1, 'turn/start', {'turn': 220}));
    tracker.observe(_event(2, 'tool/call', {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'arguments': 'ls'}));
    tracker.observe(_event(3, 'tool/result', {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'text': 'ok'}));
    tracker.observe(ChatEvent.fromJson(_replayJson()));
    final processes = tracker.build();
    expect(processes.any((process) => process.turn == 148), isFalse,
        reason: 'surface replay 不得生成历史工具结果 partial 组');
    expect(processes.any((process) => process.turn == 220), isTrue);
  });

  test('issue #99 P1：tracker 先看 replay、后到旧 source 也不得生成 turn148 partial', () {
    final tracker = TurnProcessTracker();
    tracker.observe(_event(1, 'turn/start', {'turn': 220}));
    tracker.observe(_event(2, 'tool/call', {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'arguments': 'ls'}));
    tracker.observe(_event(3, 'tool/result', {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'text': 'ok'}));
    // replay 先到，随后旧 source 9142 从另一历史页/倒序到达。
    tracker.observe(ChatEvent.fromJson(_replayJson()));
    tracker.observe(_event(9142, 'tool/result', {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'text': 'old'}));
    final processes = tracker.build();
    expect(processes.any((process) => process.turn == 148), isFalse,
        reason: 'shadowed 旧 source 不得创建 partial 组');
    expect(processes.any((process) => process.turn == 220), isTrue);
  });

  test('issue #99 P1：source 存在时 tracker 锚点仍指原 source seq', () {
    final tracker = TurnProcessTracker();
    tracker.observe(_event(1, 'turn/start', {'turn': 148}));
    tracker.observe(_event(9142, 'tool/result', {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'text': 'old'}));
    tracker.observe(ChatEvent.fromJson(_replayJson()));
    final process = tracker.build().firstWhere((item) => item.turn == 148);
    final rows = process.groups.expand((group) => group.rows).toList();
    expect(rows, hasLength(1), reason: 'replay 不得新增第二行');
    expect(rows.single.seq, 9142, reason: '工具行锚点保持原 source seq');
  });

  test('issue #99 P1：replay-only tracker 不生成 partial 组/工具行', () {
    final tracker = TurnProcessTracker();
    tracker.observe(_event(1, 'turn/start', {'turn': 220}));
    tracker.observe(ChatEvent.fromJson(_replayJson()));
    expect(tracker.build().any((process) => process.turn == 148), isFalse);
  });

  group('issue #99 widget：当前轮 + replay-only 旧工具', () {
    List<Map<String, dynamic>> fixture({bool withReplay = true}) => [
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 220}},
      {'seq': 2, 'type': 'user/message', 'data': {'messageId': 'u1', 'text': '开始', 'sourceKind': 'user'}},
      {'seq': 3, 'type': 'tool/call', 'data': {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'arguments': 'ls'}},
      {'seq': 4, 'type': 'tool/result', 'data': {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'text': 'ok'}},
      if (withReplay) _replayJson(),
      if (withReplay) ...[
        {'seq': 13284, 'type': 'assistant/message', 'data': {'turn': 220, 'step': 1, 'messageId': 'a1', 'text': '最终回答'}},
        {'seq': 13285, 'type': 'turn/end', 'data': {'turn': 220, 'reason': {'kind': 'completed'}}},
      ] else ...[
        {'seq': 5, 'type': 'assistant/message', 'data': {'turn': 220, 'step': 1, 'messageId': 'a1', 'text': '最终回答'}},
        {'seq': 6, 'type': 'turn/end', 'data': {'turn': 220, 'reason': {'kind': 'completed'}}},
      ],
    ];

    Future<AppStore> pump(WidgetTester tester) async {
      final backend = _Backend(events: fixture());
      final store = AppStore()
        ..sessionId = 'session-99'
        ..sessions = [Session(id: 'session-99', title: 'S', cwd: null, createdAt: 1)];
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(store: store, apiClient: backend.api, onTitleChanged: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 150));
      return store;
    }

    testWidgets('原 9142 + replace 13283 + 当前轮：note2312 最多一份', (tester) async {
      final events = fixture();
      // 在 replay 之前插入被替换的原始工具结果（同 callId，无 turn/start）。
      events.insert(4, {'seq': 9142, 'type': 'tool/result', 'data': {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'text': 'old note'}});
      final backend = _Backend(events: events);
      final store = AppStore()
        ..sessionId = 'session-99'
        ..sessions = [Session(id: 'session-99', title: 'S', cwd: null, createdAt: 1)];
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(store: store, apiClient: backend.api, onTitleChanged: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 150));
      expect(_toolCard(_callId), findsOneWidget,
          reason: '原 9142 与 replay 13283 必须合并为一张卡，不能各生成一张');
      expect(find.text('历史工具结果（无过程上下文）'), findsNothing,
          reason: 'surface replay 不能生成历史工具结果卡');
    });

    testWidgets('SSE append（真实字符串 shape）：不触发 shadow/不丢 source', (tester) async {
      final backend = _Backend(events: fixture(withReplay: false));
      final store = AppStore()
        ..sessionId = 'session-99'
        ..sessions = [Session(id: 'session-99', title: 'S', cwd: null, createdAt: 1)];
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(store: store, apiClient: backend.api, onTitleChanged: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('1 组 · 1 次工具调用'), findsOneWidget);
      store.injectFrame({
        'type': 'session/event',
        'sessionId': 'session-99',
        'event': {
          'seq': 13283,
          'type': 'tool/result',
          'data': {'turn': 220, 'step': 1, 'callId': 'c-now', 'name': 'bash', 'text': 'append result'},
          'surfaceOp': 'append',
          'sourceEventSeqs': [4],
        },
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1 组 · 1 次工具调用'), findsOneWidget, reason: 'append 不新增卡/组');
      expect(find.text('历史工具结果（无过程上下文）'), findsNothing);
      store.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('原工具事件后到：replay 先到也不重复，仍只一张历史卡', (tester) async {
      final backend = _Backend(events: fixture(withReplay: false));
      final store = AppStore()
        ..sessionId = 'session-99'
        ..sessions = [Session(id: 'session-99', title: 'S', cwd: null, createdAt: 1)];
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(store: store, apiClient: backend.api, onTitleChanged: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 150));
      store.injectFrame({'type': 'session/event', 'sessionId': 'session-99', 'event': _replayJson()});
      await tester.pump(const Duration(milliseconds: 200));
      expect(_toolCard(_callId), findsNothing);
      // 原始工具调用随后到达（非 replay）：与已记录的 replay 内容合并成一张卡。
      store.injectFrame({
        'type': 'session/event',
        'sessionId': 'session-99',
        'event': {
          'seq': 13284,
          'type': 'tool/call',
          'data': {'turn': 148, 'step': 1, 'callId': _callId, 'name': 'bash', 'arguments': 'ls'},
        },
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('historical-tool-results-148')), findsOneWidget,
          reason: '原事件后到仍归入同一历史组，不能多卡');
      expect(_toolCard(_callId), findsNothing, reason: '卡片由过程组承载，不额外独立');
      store.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('SSE 路径：新 seq replay frame 携带 surfaceOp 也不生成历史工具卡', (tester) async {
      final backend = _Backend(events: fixture(withReplay: false));
      final store = AppStore()
        ..sessionId = 'session-99'
        ..sessions = [Session(id: 'session-99', title: 'S', cwd: null, createdAt: 1)];
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(store: store, apiClient: backend.api, onTitleChanged: () {}),
      ));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 150));
      store.injectFrame({'type': 'session/event', 'sessionId': 'session-99', 'event': _replayJson()});
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('历史工具结果（无过程上下文）'), findsNothing);
      expect(find.byKey(const Key('historical-tool-results-148')), findsNothing);
      expect(_toolCard(_callId), findsNothing, reason: 'replay-only 不得生成旧独立工具卡');
      expect(find.textContaining('note 2312'), findsNothing);
      store.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('不出现网页没有的历史工具结果卡/旧 note2312', (tester) async {
      await pump(tester);
      expect(find.text('历史工具结果（无过程上下文）'), findsNothing);
      expect(find.byKey(const Key('historical-tool-results-148')), findsNothing);
      expect(_toolCard(_callId), findsNothing, reason: 'replay-only 不得生成旧独立工具卡');
      expect(find.textContaining('note 2312'), findsNothing);
      // 当前轮工具只出现一次。
      expect(find.text('1 组 · 1 次工具调用'), findsOneWidget);
    });
  });
}

class _Backend {
  _Backend({required this.events});
  final List<Map<String, dynamic>> events;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue99.test'
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
    final path = request.url.path;
    Map<String, dynamic> body;
    if (path == '/m/api/history') {
      body = {'ok': true, 'events': events, 'hasMore': false};
    } else if (path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
    } else if (path == '/m/api/commands' || path == '/m/api/skills') {
      body = {'ok': true, 'commands': <Object>[], 'skills': <Object>[]};
    } else {
      body = {'ok': true};
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}
