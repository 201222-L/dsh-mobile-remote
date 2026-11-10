// issue #68（M3 Batch 2-C）：PTC 子调用树的 App 侧 reducer / widget 回归。
//
// 覆盖契约（/tmp/issue68-contract.md §2-§4 / §5.4）：
// - reducer：start→result 挂根、result 先到不降级、重复事件去重、orphan 挂回、
//   同父首次顺序 + DFS 先序、深度 16、自环/祖先环/重复父、服务端 notice、
//   App 50 上限、M1 不新增条目、坏 data 回退 debug-only 事件条目；
// - widget：根卡「N 个子调用」计数、展开缩进子行（名称/状态/安全摘要）、失败态、
//   truncated 后缀、旧插件/无能力位完全降级、不生成裸 PTC 事件卡、默认收起。

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

// ── 通用夹具 ─────────────────────────────────────────────────────────────

ChatEvent _ev(String type, int seq, Map<String, dynamic> data) =>
    ChatEvent(seq: seq, type: type, data: data);

const _rootCallId = 'call-run';

Map<String, dynamic> _rootCall(int seq) => {
  'turn': 1,
  'step': 1,
  'callId': _rootCallId,
  'name': 'run_code',
  'arguments': '{"code":"await tools.read({ file_path: \\"README.md\\" })"}',
};

Map<String, dynamic> _start(
  int seq,
  String callId, {
  String parent = _rootCallId,
  String name = 'read',
  Map<String, dynamic>? summary,
}) => {
  'turn': 1,
  'step': 1,
  'rootCallId': _rootCallId,
  'parentCallId': parent,
  'callId': callId,
  'name': name,
  'status': 'running',
  'summary': ?summary,
};

Map<String, dynamic> _result(
  int seq,
  String callId, {
  String parent = _rootCallId,
  String name = 'read',
  String status = 'success',
  bool isError = false,
  String? text,
  Map<String, dynamic>? error,
  Map<String, dynamic>? summary,
}) => {
  'turn': 1,
  'step': 1,
  'rootCallId': _rootCallId,
  'parentCallId': parent,
  'callId': callId,
  'name': name,
  'status': status,
  'isError': isError,
  'text': ?text,
  'error': ?error,
  'summary': ?summary,
};

const _readSummary = {
  'kind': 'file',
  'tool': 'read',
  'filePath': 'README.md',
  'limit': 3,
};

TimelineReducer _reducerWithRoot({String root = _rootCallId, int seq = 1}) {
  final reducer = TimelineReducer();
  reducer.apply(_ev('tool/call', seq, {
    'turn': 1,
    'step': 1,
    'callId': root,
    'name': 'run_code',
    'arguments': '{}',
  }));
  return reducer;
}

List<String> _subCallIds(TimelineReducer reducer, [String root = _rootCallId]) =>
    (reducer.tools[root]?.subCalls ?? const <ToolSubCall>[])
        .map((sub) => sub.callId)
        .toList();

void main() {
  group('reducer：PTC 子调用树', () {
    test('start→result 挂到根：status 收敛、锚点 seq、summary/text 合并', () {
      final reducer = _reducerWithRoot();
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, _start(2, 's1')));
      var root = reducer.tools[_rootCallId]!;
      expect(root.subCalls, hasLength(1));
      expect(root.subCalls.single.status, 'running');
      expect(root.subCalls.single.seq, 2);
      expect(root.subCalls.single.depth, 1);
      expect(root.subCallsTruncated, isFalse);

      reducer.apply(_ev('tool/ptc-dispatch', 3, _result(3, 's1')));
      root = reducer.tools[_rootCallId]!;
      expect(root.subCalls, hasLength(1));
      expect(root.subCalls.single.status, 'success');
      expect(root.subCalls.single.isError, isFalse);
      expect(root.subCalls.single.seq, 2, reason: '首个事件锚点不变');
      // 根卡自身生命周期不受子调用影响。
      expect(root.status, 'running');
      expect(reducer.lastTouchedToolRoots, {_rootCallId});
    });

    test('result 先到 / start 后到：不降级，name 冲突 result 胜，summary 互补', () {
      final reducer = _reducerWithRoot();
      reducer.apply(_ev('tool/ptc-dispatch', 2, _result(2, 's1', name: 'read_from_result')));
      reducer.apply(_ev('tool/ptc-dispatch-start', 3, _start(3, 's1', name: 'read')));
      final node = reducer.tools[_rootCallId]!.subCalls.single;
      expect(node.status, 'success');
      expect(node.name, 'read_from_result');
      // start 的 summary 只在缺失时补。
      expect(node.summary?.filePath, isNull);
      reducer.apply(_ev('tool/ptc-dispatch-start', 4, _start(4, 's2', summary: _readSummary)));
      expect(reducer.tools[_rootCallId]!.subCalls, hasLength(2));
      expect(reducer.tools[_rootCallId]!.subCalls.last.summary?.filePath, 'README.md');
    });

    test('重复 start/result 不新增节点；重复 result 原地覆盖（last-write-wins）', () {
      final reducer = _reducerWithRoot();
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, _start(2, 's1')));
      reducer.apply(_ev('tool/ptc-dispatch-start', 3, _start(3, 's1')));
      expect(reducer.tools[_rootCallId]!.subCalls, hasLength(1));
      reducer.apply(_ev('tool/ptc-dispatch', 4, _result(4, 's1', text: 'first')));
      reducer.apply(_ev(
        'tool/ptc-dispatch',
        5,
        _result(5, 's1', status: 'failed', isError: true, text: 'FS_NOT_FOUND', error: {'name': 'FsError', 'code': 'FS_NOT_FOUND'}),
      ));
      final node = reducer.tools[_rootCallId]!.subCalls.single;
      expect(node.status, 'failed');
      expect(node.isError, isTrue);
      expect(node.text, 'FS_NOT_FOUND');
      expect(node.seq, 2);
    });

    test('orphan：父未到不渲染；根到达后挂回；父是子调用时逐层挂回；无父始终不渲染', () {
      final reducer = TimelineReducer();
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, _start(2, 's1')));
      reducer.apply(_ev('tool/ptc-dispatch', 3, _result(3, 's1', summary: _readSummary)));
      reducer.apply(_ev('tool/ptc-dispatch-start', 4, {
        ..._start(4, 's1-child', parent: 's1'),
        'name': 'grep',
      }));
      expect(reducer.items, isEmpty);
      expect(reducer.tools, isEmpty);
      expect(reducer.lastTouchedToolRoots, isEmpty, reason: '无根可刷新');

      reducer.apply(_ev('tool/call', 5, _rootCall(5)));
      final root = reducer.tools[_rootCallId]!;
      expect(_subCallIds(reducer), ['s1', 's1-child']);
      expect(root.subCalls[1].depth, 2);

      // 永远没有父的节点：不伪造根、不渲染。
      reducer.apply(_ev('tool/ptc-dispatch-start', 6, _start(6, 'orphan', parent: 'never')));
      expect(_subCallIds(reducer), ['s1', 's1-child']);
    });

    test('排序：同父按首次 seq，DFS 先序；倒序输入结果一致', () {
      List<String> run({required bool reverse}) {
        final reducer = TimelineReducer();
        final events = <ChatEvent>[
          _ev('tool/ptc-dispatch-start', 2, _start(2, 'b', name: 'bash')),
          _ev('tool/ptc-dispatch-start', 3, _start(3, 'a', name: 'read')),
          _ev('tool/ptc-dispatch-start', 4, _start(4, 'a1', parent: 'a', name: 'grep')),
          _ev('tool/ptc-dispatch-start', 5, _start(5, 'a2', parent: 'a', name: 'glob')),
          _ev('tool/call', 1, _rootCall(1)),
        ];
        for (final event in reverse ? events.reversed.toList() : events) {
          reducer.apply(event);
        }
        return _subCallIds(reducer);
      }

      // 同父按**首次 start seq**：root 的子节点 b(2) 在 a(3) 前；a 的子树紧跟 a（DFS 先序）。
      expect(run(reverse: false), ['b', 'a', 'a1', 'a2']);
      expect(run(reverse: true), ['b', 'a', 'a1', 'a2']);
    });

    test('深度 16：链式 16 层全渲染，第 17 层被截断并置 truncated', () {
      final reducer = TimelineReducer();
      // 倒序喂：最深节点先到，全部 orphan，根到达后逐层挂回。
      for (var depth = 17; depth >= 1; depth--) {
        reducer.apply(_ev(
          'tool/ptc-dispatch-start',
          100 + depth,
          _start(100 + depth, 'd$depth', parent: depth == 1 ? _rootCallId : 'd${depth - 1}', name: 'read'),
        ));
      }
      reducer.apply(_ev('tool/call', 1, _rootCall(1)));
      final root = reducer.tools[_rootCallId]!;
      expect(root.subCalls, hasLength(16));
      expect(root.subCalls.first.callId, 'd1');
      expect(root.subCalls.last.callId, 'd16');
      expect(root.subCalls.last.depth, 16);
      expect(root.subCallsTruncated, isTrue);
    });

    test('环防护：自环 / 祖先环 / 重复父 → 静默忽略、不崩溃、不置 truncated', () {
      final reducer = _reducerWithRoot();
      // 自环。
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, _start(2, 'self', parent: 'self')));
      expect(_subCallIds(reducer), isEmpty);
      // 祖先环：a 已挂根，b 挂 a，然后 a 试图挂 b。
      reducer.apply(_ev('tool/ptc-dispatch-start', 3, _start(3, 'a', parent: _rootCallId)));
      reducer.apply(_ev('tool/ptc-dispatch-start', 4, _start(4, 'b', parent: 'a')));
      // 同一 callId 的父冲突：b 想改成根（首次父胜出 → 忽略）。
      reducer.apply(_ev('tool/ptc-dispatch-start', 5, _start(5, 'b', parent: _rootCallId)));
      // 新节点 c 试图挂到自身后代路径（构造祖先环：c 的父是 b，另一个事件把 a 挂到 c）。
      reducer.apply(_ev('tool/ptc-dispatch-start', 6, _start(6, 'c', parent: 'b')));
      reducer.apply(_ev('tool/ptc-dispatch-start', 7, _start(7, 'd', parent: 'c')));
      // 重复父：d 的父已是 c，不能改挂根。
      reducer.apply(_ev('tool/ptc-dispatch-start', 8, _start(8, 'd', parent: _rootCallId)));
      expect(_subCallIds(reducer), ['a', 'b', 'c', 'd']);
      expect(reducer.tools[_rootCallId]!.subCallsTruncated, isFalse);
      expect(reducer.items.length, 1);
    });

    test('服务端 notice：不建节点、命中根置 truncated；父未到时暂存、父到达后生效', () {
      final reducer = _reducerWithRoot();
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, {
        'rootCallId': _rootCallId,
        'parentCallId': _rootCallId,
        'callId': 'notice-1',
        'name': 'read',
        'status': 'running',
        'truncated': true,
      }));
      expect(_subCallIds(reducer), isEmpty);
      expect(reducer.tools[_rootCallId]!.subCallsTruncated, isTrue);

      // 父未到的 notice：暂存后父到达挂回并生效。
      final reducer2 = TimelineReducer();
      reducer2.apply(_ev('tool/ptc-dispatch-start', 2, {
        'rootCallId': _rootCallId,
        'parentCallId': 'later-parent',
        'callId': 'notice-2',
        'name': 'read',
        'status': 'running',
        'truncated': true,
      }));
      expect(reducer2.tools, isEmpty);
      reducer2.apply(_ev('tool/ptc-dispatch-start', 3, _start(3, 'later-parent', summary: _readSummary)));
      reducer2.apply(_ev('tool/call', 1, _rootCall(1)));
      expect(reducer2.tools[_rootCallId]!.subCallsTruncated, isTrue);
    });

    test('App 侧 50 上限：60 个子调用渲染 50 条并置 truncated', () {
      final reducer = _reducerWithRoot();
      for (var index = 1; index <= 60; index++) {
        reducer.apply(_ev(
          'tool/ptc-dispatch-start',
          100 + index,
          _start(100 + index, 'many-$index', summary: _readSummary),
        ));
      }
      final root = reducer.tools[_rootCallId]!;
      expect(root.subCalls, hasLength(50));
      expect(root.subCallsTruncated, isTrue);
      expect(root.subCalls.first.callId, 'many-1');
      expect(root.subCalls.last.callId, 'many-50');
    });

    test('M1：PTC 事件只更新根卡、不新增时间线条目（根卡锚点/位置不变）', () {
      final reducer = _reducerWithRoot();
      final anchor = reducer.items.single.seq;
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, _start(2, 's1')));
      reducer.apply(_ev('tool/ptc-dispatch', 3, _result(3, 's1')));
      expect(reducer.items, hasLength(1));
      expect(reducer.items.single.kind, TimelineItemKind.tool);
      expect(reducer.items.single.callId, _rootCallId);
      expect(reducer.items.single.seq, anchor);
      // 子调用也不进入轮次过程行（turn_process 只认工具事件）。
      final tracker = TurnProcessTracker();
      for (final event in [
        _ev('tool/ptc-dispatch-start', 2, _start(2, 's1')),
        _ev('tool/ptc-dispatch', 3, _result(3, 's1')),
      ]) {
        tracker.observe(event);
      }
      expect(tracker.build(), isEmpty);
    });

    test('坏 data（缺 callId/parentCallId）→ 不建节点，落回 debug-only 事件条目', () {
      final reducer = _reducerWithRoot();
      reducer.apply(_ev('tool/ptc-dispatch-start', 2, {'name': 'read', 'status': 'running'}));
      expect(reducer.tools[_rootCallId]!.subCalls, isEmpty);
      expect(reducer.items, hasLength(2));
      final eventItem = reducer.items.last;
      expect(eventItem.kind, TimelineItemKind.event);
      expect(eventItem.type, 'tool/ptc-dispatch-start');
      expect(eventItem.filteredInOrdinary, isTrue);
    });
  });

  group('widget：根工具卡子调用', () {
    testWidgets('计数行 + 展开缩进子行（名称/状态/安全摘要）；默认收起、失败不自动展开', (tester) async {
      final backend = _PtcBackend();
      await _pumpPtcChat(tester, _store(), backend);

      final card = find.byKey(const ValueKey<String>('tool:$_rootCallId:1'));
      expect(card, findsOneWidget);
      expect(find.text('2 个子调用'), findsOneWidget);
      // 默认收起：子行不可见（失败的子调用也不会自动展开根卡，沿用 #61）。
      expect(find.byKey(const ValueKey<String>('tool-ptc-subcall:s1')), findsNothing);
      expect(find.textContaining('FS_NOT_FOUND'), findsNothing);

      await _expandCard(tester, card);
      expect(find.byKey(const ValueKey<String>('tool-ptc-subcall:s1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('tool-ptc-subcall:s2')), findsOneWidget);
      expect(find.textContaining('read · 成功 · README.md'), findsOneWidget);
      expect(find.textContaining('bash · 失败'), findsOneWidget);
      expect(find.textContaining('FS_NOT_FOUND'), findsOneWidget);
      // 无裸 PTC 事件卡（调试模式同样不出现）。
      expect(find.textContaining('tool/ptc-dispatch'), findsNothing);
    });

    testWidgets('旧插件 / 无 ptc 能力位：即便 wire 带子调用也完全降级', (tester) async {
      for (final backend in [_PtcBackend(ptcVersion: 0), _PtcBackend(toolCards: false)]) {
        await _pumpPtcChat(tester, _store(), backend);
        final card = find.byKey(const ValueKey<String>('tool:$_rootCallId:1'));
        expect(card, findsOneWidget);
        expect(find.textContaining('个子调用'), findsNothing);
        await _expandCard(tester, card);
        expect(find.byKey(const ValueKey<String>('tool-ptc-subcall:s1')), findsNothing);
        expect(find.textContaining('FS_NOT_FOUND'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('truncated：计数行带「（已截断）」后缀', (tester) async {
      final backend = _PtcBackend(truncated: true);
      await _pumpPtcChat(tester, _store(), backend);
      expect(find.text('2 个子调用（已截断）'), findsOneWidget);
    });

    testWidgets('坏 data：PTC 落到 debug-only 裸事件卡（普通模式不显示）', (tester) async {
      final debugStore = _store()..timelineDebug = true;
      await _pumpPtcChat(tester, debugStore, _PtcBackend(invalidPtc: true));
      expect(find.textContaining('tool/ptc-dispatch-start'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());

      await _pumpPtcChat(tester, _store(), _PtcBackend(invalidPtc: true));
      expect(find.textContaining('tool/ptc-dispatch-start'), findsNothing);
    });

    testWidgets('调试模式：合法 PTC 事件不生成裸事件卡；普通根卡位置不变', (tester) async {
      final backend = _PtcBackend();
      final store = _store()..timelineDebug = true;
      await _pumpPtcChat(tester, store, backend);
      expect(find.textContaining('tool/ptc-dispatch'), findsNothing);
      expect(find.byKey(const ValueKey<String>('tool:$_rootCallId:1')), findsOneWidget);
      expect(find.text('2 个子调用'), findsOneWidget);
    });
  });
}

// ── widget harness（MockClient 提供 /history 等最小端点） ─────────────────

class _PtcBackend {
  _PtcBackend({
    this.ptcVersion = 1,
    this.truncated = false,
    this.toolCards = true,
    this.invalidPtc = false,
  });

  final int ptcVersion;
  final bool truncated;
  final bool toolCards; // false = 旧插件完全不下发 toolCards 能力位
  final bool invalidPtc; // true = 坏 data（缺 parentCallId），应退回 debug-only 事件卡

  List<Map<String, dynamic>> get events => [
    {'seq': 1, 'type': 'tool/call', 'data': _rootCall(1)},
    {'seq': 2, 'type': 'tool/ptc-dispatch-start', 'data': _start(2, 's1', summary: _readSummary)},
    {'seq': 3, 'type': 'tool/ptc-dispatch', 'data': _result(3, 's1', summary: _readSummary)},
    {
      'seq': 4,
      'type': 'tool/ptc-dispatch-start',
      'data': _start(4, 's2', name: 'bash', summary: {
        'kind': 'command',
        'tool': 'bash',
        'command': 'echo ptc-fixture-ok',
      }),
    },
    {
      'seq': 5,
      'type': 'tool/ptc-dispatch',
      'data': _result(5, 's2',
        name: 'bash',
        status: 'failed',
        isError: true,
        text: 'FS_NOT_FOUND',
        error: {'name': 'FsError', 'code': 'FS_NOT_FOUND'}),
    },
    if (invalidPtc)
      {
        'seq': 6,
        'type': 'tool/ptc-dispatch-start',
        'data': {'callId': 'bad-node', 'name': 'read'},
      },
    if (truncated)
      {
        'seq': 6,
        'type': 'tool/ptc-dispatch-start',
        'data': {
          'rootCallId': _rootCallId,
          'parentCallId': _rootCallId,
          'callId': 'notice',
          'name': 'read',
          'status': 'running',
          'truncated': true,
        },
      },
    {'seq': 7, 'type': 'tool/result', 'data': {'turn': 1, 'step': 1, 'message': {'content': [{'type': 'text', 'text': 'done'}]}, 'toolCallId': _rootCallId}},
    {'seq': 8, 'type': 'turn/end', 'data': {'turn': 1, 'reason': {'kind': 'completed'}}},
  ];

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://ptc-chat.test'
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
    ..toolCardsCapabilities = toolCards
        ? ToolCardsCapabilities(
            version: 1,
            tools: const {'bash', 'read'},
            ptcVersion: ptcVersion,
          )
        : const ToolCardsCapabilities();

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/m/api/history') {
      return _json({
        'ok': true,
        'hasMore': false,
        'turnTails': const <String, dynamic>{},
        'events': events,
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

AppStore _store() => AppStore()
  ..sessionId = 'session-ptc'
  // 完全展开：M1 标准档会折叠已完成轮次，工具卡不构建。
  ..stepDisplayMode = WorkStepDisplayMode.expanded;

Future<void> _pumpPtcChat(WidgetTester tester, AppStore store, _PtcBackend backend) async {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: const ValueKey('ptc-chat'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

Future<void> _expandCard(WidgetTester tester, Finder card) async {
  await tester.ensureVisible(card);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getTopLeft(card) + const Offset(12, 12));
  await tester.pumpAndSettle();
}
