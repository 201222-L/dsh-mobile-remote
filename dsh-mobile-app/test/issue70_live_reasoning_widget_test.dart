// issue #70（ADR 0027 §2 实时态）：真实对话页上的流式思考（provisional 过程行）回归。
//
// 覆盖 issue 预审补充的验收点：
// - 实时注入 reasoning→tool→reasoning→assistant/message 的顺序、落定仅一条、无重复；
// - 活动条与过程行分工（三处不重复）；无锚点时不凭空造过程块；
// - 四档模式矩阵、运行中强制展开、50 行分批（provisional 不计入）；
// - turn/end（completed/aborted）、reset、迟到 chunk、历史回放不变；
// - 200 delta 只触发有限重建（LiveProcessCounters 计数钩子）；
// - 运行中 provisional 可展开（裁决 D1，正文 maxHeight 200 内部滚动）与收起态行高稳定。
//
// 注入方式与 issue52 相同：`AppStore.injectFrame` 构造真实 `session/event` 帧，
// 页面经 `_handleEvent` 消费；历史夹具**不含** chunk（真实 /history 也不返回）。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-70';

// ── 测试锚点（裁决 D4 批准的生产代码 key）─────────────────────────────────
const _activityBarKey = ValueKey<String>('activity-bar');
const _activityBarThinkingKey = ValueKey<String>('activity-bar-thinking');
const _activityBarToolsKey = ValueKey<String>('activity-bar-tools');
ValueKey<String> _provisionalRowKey(int turn, int step) =>
    ValueKey<String>('provisional-reasoning-row:$turn:$step');
ValueKey<String> _provisionalBodyKey(int turn, int step) =>
    ValueKey<String>('provisional-reasoning-body:$turn:$step');
ValueKey<String> _reasoningRowKey(int turn, int seq) =>
    ValueKey<String>('reasoning-row:$turn:$seq');

class _Backend {
  _Backend({
    required this.events,
    this.returnAllOnInitial = false,
    this.olderEvents = const <Map<String, dynamic>>[],
  });

  /// 仅 durable 事件；**不得**含 `assistant/chunk`（历史端点不返回 chunk）。
  final List<Map<String, dynamic>> events;

  /// 初始窗口是否忽略 limit 返回全部事件（只用于 50 行分批用例）。
  final bool returnAllOnInitial;

  /// `/history?before=` 返回的更早一页（只给「流式中上翻」用例；默认空）。
  final List<Map<String, dynamic>> olderEvents;

  /// 上翻次数（断言历史分页真的发生）。
  int beforeRequests = 0;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue70.test'
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
    if (request.url.path == '/m/api/history') {
      assert(
        !events.any(
          (e) =>
              e['type'] == 'assistant/chunk' ||
              e['type'] == 'assistant/live-chunk',
        ),
        '历史夹具不得包含 chunk（/history 不返回 chunk）',
      );
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('before')) {
        beforeRequests++;
        body = {
          'ok': true,
          'events': beforeRequests == 1
              ? olderEvents
              : const <Map<String, dynamic>>[],
          'hasMore': false,
        };
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else if (returnAllOnInitial) {
        body = {'ok': true, 'events': events, 'hasMore': false};
      } else {
        final tail =
            events.length > limit ? events.sublist(events.length - limit) : events;
        body = {
          'ok': true,
          'events': tail,
          'hasMore': events.length > tail.length,
        };
      }
    } else if (request.url.path == '/m/api/queue') {
      body = {'ok': true, 'rows': <Object>[]};
    } else if (request.url.path == '/m/api/todos') {
      body = {'ok': true, 'todos': <Object>[]};
    } else if (request.url.path == '/m/api/session-config') {
      body = {'ok': true, 'config': <String, dynamic>{}};
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

/// 夹具 F70 历史段（与 ui-spec 附录 A.1 一致）：step1 已落定 + 1 次 shell。
List<Map<String, dynamic>> _f70History({bool withTurnEnd = false}) => [
      {
        'seq': 1,
        'type': 'turn/start',
        'data': {'turn': 1},
        'time': 1000,
      },
      {
        'seq': 2,
        'type': 'user/message',
        'data': {
          'messageId': 'u1',
          'text': 'Question 1',
          'sourceKind': 'user',
        },
        'time': 1100,
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 1,
          'messageId': 'a1',
          'text': 'Let me check the layout.',
          'reasoning': 'check layout',
          'reasoningChars': 12,
        },
        'time': 1200,
      },
      {
        'seq': 4,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-1',
          'name': 'shell',
          'arguments': '{"command":"ls"}',
        },
        'time': 1300,
      },
      {
        'seq': 5,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 1,
          'callId': 'call-1',
          'name': 'shell',
          'text': 'ok',
        },
        'time': 1400,
      },
      if (withTurnEnd)
        {
          'seq': 6,
          'type': 'turn/end',
          'data': {
            'turn': 1,
            'reason': {'kind': 'completed'},
          },
          'time': 5000,
        },
    ];

/// 夹具 F70 实时段（seq 严格递增，从历史末条之后开始）。
List<Map<String, dynamic>> _f70Live() => [
      {
        'seq': 6,
        'type': 'assistant/chunk',
        'data': {
          'turn': 1,
          'step': 2,
          'reasoning': true,
          'text': 'three modules\n',
        },
        'time': 1500,
      },
      {
        'seq': 7,
        'type': 'assistant/chunk',
        'data': {
          'turn': 1,
          'step': 2,
          'reasoning': true,
          'text': 'run tests first',
        },
        'time': 1600,
      },
      {
        'seq': 8,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'call-2',
          'name': 'shell',
          'arguments': '{"command":"flutter test"}',
        },
        'time': 1700,
      },
      {
        'seq': 9,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'call-2',
          'name': 'shell',
          'text': 'ok',
        },
        'time': 1800,
      },
      {
        'seq': 10,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 2,
          'messageId': 'a2',
          'text': '',
          'reasoning': 'three modules\nrun tests first',
          'reasoningChars': 29,
        },
        'time': 1900,
      },
      {
        'seq': 11,
        'type': 'assistant/chunk',
        'data': {'turn': 1, 'step': 2, 'text': 'All tests pass.'},
        'time': 2000,
      },
      {
        'seq': 12,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 2,
          'messageId': 'a3',
          'text': 'All tests pass.',
        },
        'time': 2100,
      },
      {
        'seq': 13,
        'type': 'turn/end',
        'data': {
          'turn': 1,
          'reason': {'kind': 'completed'},
        },
        'time': 5000,
      },
    ];

Future<AppStore> _pumpChat(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
  TurnFoldTiming timing = TurnFoldTiming.afterAnswer,
  String keySuffix = '',
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [
      Session(id: _session, title: 'S', cwd: null, createdAt: 1),
    ]
    ..stepDisplayMode = mode
    ..turnFoldTiming = timing;
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        key: ValueKey<String>('issue70-$keySuffix-${mode.name}'),
        store: store,
        apiClient: backend.api,
        onTitleChanged: () {},
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return store;
}

void _injectRaw(AppStore store, Map<String, dynamic> event) {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': event,
  });
}

Future<void> _inject(
  WidgetTester tester,
  AppStore store,
  Map<String, dynamic> event,
) async {
  _injectRaw(store, event);
  await tester.pump();
}

/// 依次注入 F70 实时帧直到（含）[lastSeq]：每帧后 pump 一帧（不推进节流计时器）。
Future<void> _injectF70To(
  WidgetTester tester,
  AppStore store,
  int lastSeq,
) async {
  for (final event in _f70Live()) {
    if ((event['seq'] as int) > lastSeq) break;
    await _inject(tester, store, event);
  }
}

/// 让 store 侧 800ms 会话去抖 / 通知去抖计时器落地，避免测试结束时报「Timer 仍挂起」。
Future<void> _flushAppTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 900));
}

List<double> _ysOf(WidgetTester tester, Finder finder) => finder
    .evaluate()
    .map((element) => tester.getTopLeft(find.byWidget(element.widget)).dy)
    .toList();

void main() {
  setUp(() {
    L10n.lang = 'zh';
    LiveProcessCounters.reset();
  });
  tearDown(() => L10n.lang = 'zh');

  testWidgets('流式交错：思考→落定→工具→新 step 思考→落定，顺序正确且落定仅一条', (
    tester,
  ) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));

    // seq6：step2 首个 reasoning chunk（该 step 还没有任何持久行 → 追加在块末尾）。
    await _inject(tester, store, _f70Live()[0]);
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('three modules'), findsOneWidget);
    expect(
      find.byKey(_activityBarKey),
      findsNothing,
      reason: '块内已有 reasoning 行 → 活动条整条不渲染（三处不重复）',
    );

    // seq7：第二个 delta 只增长文本，最近行预览更新。
    await _inject(tester, store, _f70Live()[1]);
    expect(find.text('run tests first'), findsOneWidget);

    // seq8：运行中工具到达 → 活动条只显示工具行，不显示思考文本。
    await _inject(tester, store, _f70Live()[2]);
    expect(find.byKey(_activityBarKey), findsOneWidget);
    expect(find.byKey(_activityBarThinkingKey), findsNothing);
    expect(find.byKey(_activityBarToolsKey), findsOneWidget);
    expect(find.text('正在调用 shell…'), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);

    // 顺序：step1 落定思考 → step1 工具 → step2 思考(provisional) → step2 工具。
    final reasoning1Y = tester.getTopLeft(find.text('check layout')).dy;
    final provisionalY =
        tester.getTopLeft(find.byKey(_provisionalRowKey(1, 2))).dy;
    final shellYs = _ysOf(tester, find.text('shell'))..sort();
    expect(shellYs, hasLength(2));
    expect(reasoning1Y, lessThan(shellYs.first));
    expect(shellYs.first, lessThan(provisionalY));
    expect(provisionalY, lessThan(shellYs.last));

    // seq9：工具结束、块内 reasoning 仍可见、无运行中工具 → 活动条整条消失。
    await _inject(tester, store, _f70Live()[3]);
    expect(find.byKey(_activityBarKey), findsNothing);

    // seq10 落定：provisional 消失，同一 step 恰好一条持久行。
    await _inject(tester, store, _f70Live()[4]);
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 6)), findsOneWidget);
    expect(find.byKey(_reasoningRowKey(1, 3)), findsOneWidget);
    // 落定行回到既有「首行预览」规则（不是运行中的最近行预览）。
    expect(find.text('three modules'), findsOneWidget);
    expect(find.text('run tests first'), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_activityBarKey), findsNothing);

    // 正文流式 + 落定回答：气泡只一份，且气泡内不重复思维链（inProcess 抑制）。
    await _inject(tester, store, _f70Live()[5]);
    await tester.pump(const Duration(milliseconds: 100));
    await _inject(tester, store, _f70Live()[6]);
    expect(find.text('All tests pass.'), findsOneWidget);
    expect(find.textContaining('思维链 29 字'), findsNothing);

    // seq13 turn/end：折叠摘要只计持久行（12+29=41，绝不含 provisional 的 29×2）。
    await _inject(tester, store, _f70Live()[7]);
    expect(find.textContaining('思考 41 字 · 2 组 · 2 次工具调用'), findsOneWidget);
    expect(find.textContaining('思考 70 字'), findsNothing);
    expect(find.textContaining('已完成 · 用时 4.0 秒'), findsOneWidget);
    expect(find.text('思考中…'), findsNothing);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });


  testWidgets('落定零位移：provisional 与持久行同槽，工具卡 y 不变', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _injectF70To(tester, store, 9);
    final provisionalY =
        tester.getTopLeft(find.byKey(_provisionalRowKey(1, 2))).dy;
    final toolBefore = tester
        .getTopLeft(find.byKey(const ValueKey('tool:call-2:8')))
        .dy;
    expect(provisionalY, lessThan(toolBefore));

    await _inject(tester, store, _f70Live()[4]);
    final settledY = tester.getTopLeft(find.byKey(_reasoningRowKey(1, 6))).dy;
    final toolAfter = tester
        .getTopLeft(find.byKey(const ValueKey('tool:call-2:8')))
        .dy;
    expect(settledY, closeTo(provisionalY, 0.5),
        reason: '落定后持久行继承首 delta seq，位置不跳动');
    expect(toolAfter, closeTo(toolBefore, 0.5));
    // 同一 step 的思考行仍在工具行之前。
    expect(settledY, lessThan(toolAfter));
    await _flushAppTimers(tester);
  });


  testWidgets('工具先到：provisional 追加在该工具行之后（到达顺序）', (tester) async {
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
      ]),
    );
    await _inject(tester, store, {
      'seq': 10,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-1',
        'name': 'shell',
        'arguments': '{}',
      },
      'time': 1200,
    });
    await _inject(tester, store, {
      'seq': 11,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'consider later',
      },
      'time': 1300,
    });
    final toolY = tester.getTopLeft(find.text('shell')).dy;
    final provisionalY =
        tester.getTopLeft(find.byKey(_provisionalRowKey(1, 1))).dy;
    expect(provisionalY, greaterThan(toolY), reason: '工具先到 → provisional 在其后');
    await _flushAppTimers(tester);
  });


  testWidgets('思考先到、工具后到：provisional 不跳到工具后面', (tester) async {
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
      ]),
    );
    // 无锚点阶段：保留活动条思考，不凭空造过程块。
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'think first',
      },
      'time': 1200,
    });
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    expect(find.byKey(_activityBarKey), findsOneWidget);
    expect(find.text('思考中…（11 字）'), findsOneWidget);

    await _inject(tester, store, {
      'seq': 11,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-1',
        'name': 'shell',
        'arguments': '{}',
      },
      'time': 1300,
    });
    final toolY = tester.getTopLeft(find.text('shell')).dy;
    final provisionalY =
        tester.getTopLeft(find.byKey(_provisionalRowKey(1, 1))).dy;
    expect(provisionalY, lessThan(toolY), reason: '思考先到 → 工具到达后仍在其前');
    expect(find.byKey(_activityBarThinkingKey), findsNothing);
    expect(find.text('正在调用 shell…'), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('工具类事件推进 step：旧 step provisional 关闭，迟到旧 chunk 不复活（审查 P1-2）', (
    tester,
  ) async {
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
      ]),
    );
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'step one thinking',
      },
      'time': 1200,
    });
    expect(find.byKey(_activityBarKey), findsOneWidget);
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);

    // step2 先到的是 tool/call（没有 step1 的 assistant/message）→ 必须关闭旧 provisional。
    await _inject(tester, store, {
      'seq': 11,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 2,
        'callId': 'call-2',
        'name': 'shell',
        'arguments': '{}',
      },
      'time': 1300,
    });
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_activityBarThinkingKey), findsNothing);
    expect(find.text('正在调用 shell…'), findsOneWidget);

    // 迟到的 step1 chunk：tombstone 生效，不复活。
    await _inject(tester, store, {
      'seq': 12,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'late step one',
      },
      'time': 1400,
    });
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.text('late step one'), findsNothing);
    await _flushAppTimers(tester);
  });

  testWidgets('同 step 工具事件不误关 provisional；随后 assistant/message 正常落定', (
    tester,
  ) async {
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
      ]),
    );
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'keep thinking',
      },
      'time': 1200,
    });
    await _inject(tester, store, {
      'seq': 11,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-1',
        'name': 'shell',
        'arguments': '{}',
      },
      'time': 1300,
    });
    expect(
      find.byKey(_provisionalRowKey(1, 1)),
      findsOneWidget,
      reason: '同 step 的工具事件不得关闭 provisional',
    );
    expect(find.text('思考中…'), findsOneWidget);

    await _inject(tester, store, {
      'seq': 12,
      'type': 'assistant/message',
      'data': {
        'turn': 1,
        'step': 1,
        'messageId': 'a1',
        'text': '',
        'reasoning': 'keep thinking',
        'reasoningChars': 13,
      },
      'time': 1400,
    });
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 10)), findsOneWidget);
    await _flushAppTimers(tester);
  });

  testWidgets('带 toolCall 的 chunk 也触发 step 前进检测（同 step 不误关）', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _inject(tester, store, _f70Live()[0]); // seq6 reasoning step2
    await _inject(tester, store, _f70Live()[1]); // seq7 reasoning step2
    // 同 step 的工具增量 chunk：不得关闭 provisional。
    await _inject(tester, store, {
      'seq': 8,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'toolCall': 'shell',
        'argumentsDelta': '{"command":"ls"}',
      },
      'time': 1700,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);

    // step3 的工具增量 chunk：旧 step2 provisional 关闭。
    await _inject(tester, store, {
      'seq': 9,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 3,
        'toolCall': 'read_file',
        'argumentsDelta': '{}',
      },
      'time': 1800,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    await _flushAppTimers(tester);
  });

  testWidgets('活动条三态：无锚点显示思考 / 有块有工具只显示工具 / 有块无工具整条隐藏', (
    tester,
  ) async {
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
      ]),
    );
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'hello\nworld',
      },
      'time': 1200,
    });
    expect(find.byKey(_activityBarKey), findsOneWidget);
    expect(find.text('思考中…（11 字）'), findsOneWidget);
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);

    // 工具到达：活动条只显示工具；同源快照进入过程块。
    await _inject(tester, store, {
      'seq': 11,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-1',
        'name': 'shell',
        'arguments': '{}',
      },
      'time': 1300,
    });
    expect(find.byKey(_activityBarToolsKey), findsOneWidget);
    expect(find.byKey(_activityBarThinkingKey), findsNothing);
    expect(find.text('正在调用 shell…'), findsOneWidget);
    expect(find.byKey(_provisionalRowKey(1, 1)), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);

    // 工具结束、仅剩思考中 → 活动条整条隐藏（思考已在过程行）。
    await _inject(tester, store, {
      'seq': 12,
      'type': 'tool/result',
      'data': {
        'turn': 1,
        'step': 1,
        'callId': 'call-1',
        'name': 'shell',
        'text': 'ok',
      },
      'time': 1400,
    });
    expect(find.byKey(_activityBarKey), findsNothing);
    expect(find.text('思考中…'), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('四档模式运行中：provisional 均可见、抬头细节按档位、无组抬头档位不合成', (
    tester,
  ) async {
    for (final mode in WorkStepDisplayMode.values) {
      final store = await _pumpChat(
        tester,
        _Backend(events: _f70History()),
        mode: mode,
        keySuffix: 'modes-${mode.name}',
      );
      await _injectF70To(tester, store, 8);

      expect(
        find.byKey(_provisionalRowKey(1, 2)),
        findsOneWidget,
        reason: '${mode.name}: provisional 行四档均可见',
      );
      expect(find.text('思考中…'), findsOneWidget, reason: mode.name);
      expect(find.text('run tests first'), findsOneWidget,
          reason: '${mode.name}: 运行中预览不受 settledReasoningPreview 影响');

      switch (mode) {
        case WorkStepDisplayMode.concise:
          expect(find.text('正在调用工具…'), findsOneWidget);
          expect(find.textContaining('（shell）'), findsNothing);
          // 简洁档 settledReasoningPreview=false：落定行不显示首行预览（运行中不受影响）。
          expect(find.text('check layout'), findsNothing);
          expect(find.text('思维链 12 字'), findsOneWidget);
        case WorkStepDisplayMode.standard:
          expect(find.text('正在调用工具…（shell）'), findsOneWidget);
          expect(find.text('check layout'), findsOneWidget);
        case WorkStepDisplayMode.detailed:
        case WorkStepDisplayMode.expanded:
          expect(find.textContaining('正在调用工具…'), findsNothing,
              reason: '${mode.name}: 运行中不分组，不出现组抬头');
          expect(find.text('shell'), findsNWidgets(2));
      }
      // 运行中组强制展开：provisional 与落定行都真实构建出来。
      expect(find.text('check layout'), mode == WorkStepDisplayMode.concise
          ? findsNothing
          : findsOneWidget);
      expect(tester.takeException(), isNull, reason: mode.name);
    }
    await _flushAppTimers(tester);
  });


  testWidgets('50 行分批：provisional 不计入，落定后正常计数 +1', (tester) async {
    final events = <Map<String, dynamic>>[
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': 'run many tools', 'sourceKind': 'user'},
        'time': 1100,
      },
      for (var i = 0; i < 60; i++) ...[
        {
          'seq': 10 + i * 2,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'bulk-$i',
            'name': 'shell',
            'arguments': 'echo $i',
          },
          'time': 1200 + i,
        },
        {
          'seq': 11 + i * 2,
          'type': 'tool/result',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'bulk-$i',
            'name': 'shell',
            'text': 'ok $i',
          },
          'time': 1201 + i,
        },
      ],
    ];
    final store = await _pumpChat(
      tester,
      _Backend(events: events, returnAllOnInitial: true),
    );
    await _inject(tester, store, {
      'seq': 500,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 1, 'reasoning': true, 'text': 'still thinking'},
      'time': 2000,
    });
    // 夹具较大，过程块在视口之外：先滚到块真正构建出来再断言（懒构建）。
    await tester.dragUntilVisible(
      find.byKey(_provisionalRowKey(1, 1)),
      find.byType(CustomScrollView),
      const Offset(0, 800),
      maxIteration: 120,
    );
    expect(find.byKey(_provisionalRowKey(1, 1)), findsOneWidget);
    expect(find.textContaining('显示更多（还有 10 行）'), findsOneWidget,
        reason: 'provisional 不进入 50 行计数');

    await _inject(tester, store, {
      'seq': 501,
      'type': 'assistant/message',
      'data': {
        'turn': 1,
        'step': 1,
        'messageId': 'a1',
        'text': '',
        'reasoning': 'still thinking',
        'reasoningChars': 14,
      },
      'time': 2100,
    });
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    await tester.dragUntilVisible(
      find.textContaining('显示更多（还有 11 行）'),
      find.byType(CustomScrollView),
      const Offset(0, 800),
      maxIteration: 120,
    );
    expect(find.textContaining('显示更多（还有 11 行）'), findsOneWidget,
        reason: '落定后持久行按正常规则计数');
    await _flushAppTimers(tester);
  });


  testWidgets('turn/end completed：provisional 立即消失、页脚有用时、无残留', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _injectF70To(tester, store, 8);
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);

    await _inject(tester, store, {
      'seq': 20,
      'type': 'turn/end',
      'data': {'turn': 1, 'reason': {'kind': 'completed'}},
      'time': 5000,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_activityBarKey), findsNothing);
    expect(find.textContaining('已完成 · 用时 4.0 秒'), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('turn/end aborted：中断轮不残留 provisional、页脚不显示用时', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _injectF70To(tester, store, 8);
    await _inject(tester, store, {
      'seq': 20,
      'type': 'turn/end',
      'data': {'turn': 1, 'reason': {'kind': 'aborted'}},
      'time': 5000,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.textContaining('已中止'), findsOneWidget);
    expect(find.textContaining('用时'), findsNothing);
    await _flushAppTimers(tester);
  });


  testWidgets('reset（compaction/end）：缓冲清空，旧轮迟到 chunk 不复活 provisional', (
    tester,
  ) async {
    final history = <Map<String, dynamic>>[
      ..._f70History(withTurnEnd: true),
      {'seq': 7, 'type': 'turn/start', 'data': {'turn': 2}, 'time': 6000},
      {
        'seq': 8,
        'type': 'user/message',
        'data': {'messageId': 'u2', 'text': 'Question 2', 'sourceKind': 'user'},
        'time': 6100,
      },
    ];
    final store = await _pumpChat(tester, _Backend(events: history));
    await _inject(tester, store, {
      'seq': 20,
      'type': 'assistant/chunk',
      'data': {
        'turn': 2,
        'step': 1,
        'reasoning': true,
        'text': 'while running',
      },
      'time': 7000,
    });
    expect(find.textContaining('正在调用工具…'), findsNothing);
    expect(find.byKey(_activityBarKey), findsOneWidget,
        reason: 'turn2 尚无持久过程行 → 无锚点，活动条保留思考');
    expect(find.text('思考中…（13 字）'), findsOneWidget);

    // compaction/end → _load(reset:true)：重建表面、清空流式缓冲与活动条状态。
    await _inject(tester, store, {
      'seq': 21,
      'type': 'compaction/end',
      'data': {'turn': 2},
      'time': 7100,
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_activityBarKey), findsNothing);
    expect(find.textContaining('思考中'), findsNothing);
    expect(find.textContaining('思考 12 字 · 1 组 · 1 次工具调用'), findsOneWidget,
        reason: '历史回放外观不变（旧轮已落定摘要仍在）');
    expect(find.text('check layout'), findsNothing);

    // 旧轮（turn1 已结束）迟到 chunk：tombstone 生效，不复活 provisional。
    await _inject(tester, store, {
      'seq': 22,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 2, 'reasoning': true, 'text': 'late old turn'},
      'time': 7200,
    });
    expect(find.text('思考中…'), findsNothing);
    expect(find.text('late old turn'), findsNothing);
    expect(find.byKey(_activityBarKey), findsNothing);
    await _flushAppTimers(tester);
  });


  testWidgets('reset 后仍在运行轮：已落定 step 迟到 chunk 不复活 provisional，新 step 正常', (
    tester,
  ) async {
    final history = <Map<String, dynamic>>[
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': 'Question live', 'sourceKind': 'user'},
        'time': 1100,
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'step': 1,
          'messageId': 'a1',
          'text': '',
          'reasoning': 'settled step one',
          'reasoningChars': 16,
        },
        'time': 1200,
      },
      {
        'seq': 4,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'call-2',
          'name': 'shell',
          'arguments': '{}',
        },
        'time': 1300,
      },
      {
        'seq': 5,
        'type': 'tool/result',
        'data': {
          'turn': 1,
          'step': 2,
          'callId': 'call-2',
          'name': 'shell',
          'text': 'ok',
        },
        'time': 1400,
      },
    ];
    final store = await _pumpChat(tester, _Backend(events: history));

    // reset/reload：durable 回放只读登记 (turn1,step1) 落定水位，不写 live tombstone。
    await _inject(tester, store, {
      'seq': 6,
      'type': 'compaction/end',
      'data': {'turn': 1},
      'time': 1500,
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(_reasoningRowKey(1, 3)), findsOneWidget);
    expect(find.text('settled step one'), findsOneWidget);

    // 迟到 step1 chunk：该 step 已落定 → 丢弃，不复活 provisional、不新增第二行。
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 1,
        'reasoning': true,
        'text': 'late settled chunk',
      },
      'time': 1600,
    });
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.text('late settled chunk'), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 3)), findsOneWidget);
    expect(find.text('settled step one'), findsOneWidget);

    // 后续新 step：step2 chunk 必须正常进入 provisional（水位只挡已落定 step）。
    await _inject(tester, store, {
      'seq': 11,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': 'step two thinking',
      },
      'time': 1700,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('step two thinking'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });

  testWidgets('迟到 chunk：落定后同 (turn, step) 的 reasoning 被丢弃', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _inject(tester, store, _f70Live()[0]);
    await _inject(tester, store, _f70Live()[1]);
    await _inject(tester, store, _f70Live()[4]); // 落定 step2
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 6)), findsOneWidget);
    final before = LiveProcessCounters.structuralChanges;

    await _inject(tester, store, {
      'seq': 20,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 2, 'reasoning': true, 'text': 'late chunk'},
      'time': 2000,
    });
    expect(LiveProcessCounters.structuralChanges, before);
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.text('late chunk'), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 6)), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('assistant/message 无 reasoning 字段：provisional 也清掉且不新增行', (
    tester,
  ) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 2, 'reasoning': true, 'text': 'old host'},
      'time': 1200,
    });
    await _inject(tester, store, {
      'seq': 11,
      'type': 'assistant/message',
      'data': {'turn': 1, 'step': 2, 'messageId': 'a2', 'text': ''},
      'time': 1300,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 10)), findsNothing);
    expect(find.byKey(_reasoningRowKey(1, 3)), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('切 step：只保留一条 provisional，预览为新 step 最近行', (tester) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 2, 'reasoning': true, 'text': 'step two'},
      'time': 1200,
    });
    await _inject(tester, store, {
      'seq': 11,
      'type': 'assistant/message',
      'data': {
        'turn': 1,
        'step': 2,
        'messageId': 'a2',
        'text': '',
        'reasoning': 'step two',
        'reasoningChars': 8,
      },
      'time': 1300,
    });
    await _inject(tester, store, {
      'seq': 12,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 3, 'reasoning': true, 'text': 'step three'},
      'time': 1400,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsNothing);
    expect(find.byKey(_provisionalRowKey(1, 3)), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);
    // 新 step 没有持久行：按契约 B2 追加在块末尾，不合成组抬头（裁决 D2）。
    expect(find.textContaining('正在思考…'), findsNothing);

    await _inject(tester, store, {
      'seq': 13,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 3,
        'callId': 'call-3',
        'name': 'read_file',
        'arguments': '{}',
      },
      'time': 1500,
    });
    final toolY = tester.getTopLeft(find.text('read_file')).dy;
    final provisionalY =
        tester.getTopLeft(find.byKey(_provisionalRowKey(1, 3))).dy;
    expect(provisionalY, lessThan(toolY), reason: '思考先到 → 新工具行在其后');
    expect(find.text('正在调用工具…（read_file）'), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('流式中上翻更早历史：durable 回放不得误清/推进 provisional（复审 P1）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final backend = _Backend(
      events: [
        {'seq': 20, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 2000},
        {
          'seq': 21,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Question live', 'sourceKind': 'user'},
          'time': 2100,
        },
        {
          'seq': 22,
          'type': 'assistant/message',
          'data': {
            'turn': 1,
            'step': 1,
            'messageId': 'a1',
            'text': 'step one reply',
            'reasoning': 'check layout',
            'reasoningChars': 12,
          },
          'time': 2200,
        },
        {
          'seq': 23,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-1',
            'name': 'shell',
            'arguments': 'ls',
          },
          'time': 2300,
        },
        {
          'seq': 24,
          'type': 'tool/result',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-1',
            'name': 'shell',
            'text': 'ok',
          },
          'time': 2400,
        },
      ],
      // 更早的历史页：同 turn 的无 step 思考（旧实现会 closeStep(1,null) 误关当前
      // step2，并写 tombstone 让后续 chunk 永久丢弃）+ 同 turn 更大 step 的工具事件
      // （旧实现会误推进 step）。两者都不得触碰 live 缓冲。
      olderEvents: const [
        {
          'seq': 10,
          'type': 'assistant/message',
          'data': {
            'turn': 1,
            'messageId': 'old-a',
            'text': 'legacy older reply',
            'reasoning': 'legacy older thought',
            'reasoningChars': 20,
          },
          'time': 1000,
        },
        {
          'seq': 11,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 9,
            'callId': 'old-call',
            'name': 'read_file',
            'arguments': '{}',
          },
          'time': 1100,
        },
      ],
    );
    final store = await _pumpChat(tester, backend);

    // 流式 provisional（turn1/step2）：已有 step1 持久行作为过程块锚点。
    await _inject(tester, store, {
      'seq': 30,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': 'live thought\n',
      },
      'time': 3000,
    });
    await _inject(tester, store, {
      'seq': 31,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': 'run tests first',
      },
      'time': 3100,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('run tests first'), findsOneWidget);

    // 用户上翻 → 加载更早历史页（durable 回放，不得对 live 缓冲有副作用）。
    for (var i = 0; i < 30 && backend.beforeRequests == 0; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(backend.beforeRequests, greaterThan(0), reason: '上翻应触发 before 分页');

    // 回到实时区（懒构建可能回收了过程块），provisional 必须仍在、文案未变。
    for (var i = 0;
        i < 40 && find.byKey(_provisionalRowKey(1, 2)).evaluate().isEmpty;
        i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget,
        reason: '历史回放不得关闭流式 provisional');
    expect(find.text('思考中…'), findsOneWidget);
    expect(find.text('run tests first'), findsOneWidget);

    // 后续同 (turn, step) chunk 必须继续增长（未被 tombstone 丢弃）。
    await _inject(tester, store, {
      'seq': 32,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': ' + done',
      },
      'time': 3200,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);
    expect(find.text('run tests first + done'), findsOneWidget,
        reason: '回放后同 step chunk 仍应继续增长');
    expect(find.text('思考中…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });

  testWidgets('历史无 step 的多条思考行全部保留（审查 P1-1 用户可见回归）', (tester) async {
    final history = <Map<String, dynamic>>[
      {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': 'legacy question', 'sourceKind': 'user'},
        'time': 1100,
      },
      {
        'seq': 3,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'messageId': 'a1',
          'text': 'legacy reply one',
          'reasoning': 'legacy one',
          'reasoningChars': 10,
        },
        'time': 1200,
      },
      {
        'seq': 5,
        'type': 'assistant/message',
        'data': {
          'turn': 1,
          'messageId': 'a2',
          'text': 'legacy reply two',
          'reasoning': 'legacy two',
          'reasoningChars': 10,
        },
        'time': 1300,
      },
    ];
    await _pumpChat(tester, _Backend(events: history), keySuffix: 'legacy-nostep');
    expect(find.byKey(_reasoningRowKey(1, 3)), findsOneWidget);
    expect(find.byKey(_reasoningRowKey(1, 5)), findsOneWidget);
    final y1 = tester.getTopLeft(find.byKey(_reasoningRowKey(1, 3))).dy;
    final y2 = tester.getTopLeft(find.byKey(_reasoningRowKey(1, 5))).dy;
    expect(y1, lessThan(y2), reason: '缺 step 的思考行按 seq 排序、逐条保留');
    expect(find.text('legacy one'), findsOneWidget);
    expect(find.text('legacy two'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });

  testWidgets('历史回放不变：无 chunk 夹具不出现 provisional / 活动条', (tester) async {
    // 运行中的历史轮（无 turn/end）：过程块强制展开、无 provisional。
    await _pumpChat(tester, _Backend(events: _f70History()), keySuffix: 'hist-run');
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_activityBarKey), findsNothing);
    expect(find.byKey(_provisionalRowKey(1, 1)), findsNothing);
    expect(find.text('check layout'), findsOneWidget);
    expect(find.text('1 次工具调用'), findsOneWidget);

    // 已完成轮：折叠摘要与页脚沿用既有规则（issue52 回归口径）。
    await _pumpChat(
      tester,
      _Backend(events: _f70History(withTurnEnd: true)),
      keySuffix: 'hist-done',
    );
    expect(find.textContaining('思考 12 字 · 1 组 · 1 次工具调用'), findsOneWidget);
    expect(find.textContaining('已完成 · 用时 4.0 秒'), findsOneWidget);
    expect(find.text('思考中…'), findsNothing);
    expect(find.byKey(_activityBarKey), findsNothing);
    await tester.tap(find.textContaining('思考 12 字 · 1 组 · 1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('1 次工具调用'), findsOneWidget);
    // 完成态过程组默认折叠：再展开组才构建落定思考行（issue52 既有规则）。
    await tester.tap(find.text('1 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('check layout'), findsOneWidget);
    await _flushAppTimers(tester);
  });


  testWidgets('provisional 展开：正文高 ≤200 且内部滚动；收起态行高在 delta 间稳定', (
    tester,
  ) async {
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _injectF70To(tester, store, 7);
    final collapsedHeight = tester
        .getSize(find.byKey(_provisionalRowKey(1, 2)))
        .height;

    // 收起态：最近一行预览，行高恒定。
    await _inject(tester, store, {
      'seq': 8,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': '\n${'A' * 130}',
      },
      'time': 1700,
    });
    expect(find.text('${'A' * 119}…'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(_provisionalRowKey(1, 2))).height,
      collapsedHeight,
      reason: '收起态连续 delta 行高相等',
    );

    // 展开态：全文 + 最近字数标签，正文 maxHeight 200 内部滚动。
    await tester.tap(find.byKey(_provisionalRowKey(1, 2)));
    await tester.pump();
    expect(find.textContaining('思考中…（'), findsOneWidget);
    final bodyFinder = find.byKey(_provisionalBodyKey(1, 2));
    expect(bodyFinder, findsOneWidget);
    expect(
      tester.getSize(bodyFinder).height,
      lessThanOrEqualTo(200),
      reason: '展开正文不得撑高消息流',
    );
    expect(
      find.descendant(of: bodyFinder, matching: find.byType(SingleChildScrollView)),
      findsOneWidget,
    );
    // delta 到达不重置用户展开态。
    await _inject(tester, store, {
      'seq': 9,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 2, 'reasoning': true, 'text': ' tail'},
      'time': 1800,
    });
    expect(find.byKey(_provisionalBodyKey(1, 2)), findsOneWidget);
    expect(find.textContaining('思考中…（'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });


  testWidgets('活动条正文流式：无块时显示「已思考 N 字」，有块时不重复', (tester) async {
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
      ]),
    );
    await _inject(tester, store, {
      'seq': 10,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 1, 'reasoning': true, 'text': 'hello world'},
      'time': 1200,
    });
    expect(find.text('思考中…（11 字）'), findsOneWidget);
    await _inject(tester, store, {
      'seq': 11,
      'type': 'assistant/chunk',
      'data': {'turn': 1, 'step': 1, 'text': 'answer'},
      'time': 1300,
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已思考 11 字'), findsOneWidget, reason: '无块时保留现状文案');
    await _flushAppTimers(tester);
  });


  testWidgets('320dp 窄屏：provisional 行单行省略、无 overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = await _pumpChat(tester, _Backend(events: _f70History()));
    await _injectF70To(tester, store, 8);
    await _inject(tester, store, {
      'seq': 14,
      'type': 'assistant/chunk',
      'data': {
        'turn': 1,
        'step': 2,
        'reasoning': true,
        'text': '\n${'W' * 200}',
      },
      'time': 2100,
    });
    expect(find.byKey(_provisionalRowKey(1, 2)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });


  testWidgets('性能：200 个 delta 分批注入，页面/计划重建有限且正文完整（审查 P2-2）', (
    tester,
  ) async {
    // 已有持久工具行（过程块锚点已存在），provisional 尚未出现。
    final store = await _pumpChat(
      tester,
      _Backend(events: [
        {'seq': 1, 'type': 'turn/start', 'data': {'turn': 1}, 'time': 1000},
        {
          'seq': 2,
          'type': 'user/message',
          'data': {'messageId': 'u1', 'text': 'Q', 'sourceKind': 'user'},
          'time': 1100,
        },
        {
          'seq': 3,
          'type': 'tool/call',
          'data': {
            'turn': 1,
            'step': 1,
            'callId': 'call-1',
            'name': 'shell',
            'arguments': '{}',
          },
          'time': 1200,
        },
      ]),
    );
    LiveProcessCounters.reset();

    // 分批注入 + 逐帧 pump（每批 5 条，40 帧）：避免「一次性注入后只 pump 一次」
    // 把逐 delta 重建掩盖成单帧合并，真正验证每帧只更新该行。
    final deltas = <String>[];
    const batchSize = 5;
    const frame = Duration(milliseconds: 16);
    var frames = 0;
    for (var i = 0; i < 200; i += batchSize) {
      for (var j = 0; j < batchSize && i + j < 200; j++) {
        final delta = 'd${i + j} ';
        deltas.add(delta);
        _injectRaw(store, {
          'seq': 10 + i + j,
          'type': 'assistant/chunk',
          'data': {'turn': 1, 'step': 1, 'reasoning': true, 'text': delta},
          'time': 1300 + i + j,
        });
      }
      await tester.pump(frame);
      frames++;
    }
    expect(frames, 40);
    final fullText = deltas.join();
    expect(fullText.length, deltas.fold<int>(0, (sum, d) => sum + d.length));

    // 钩子必须真实非 0（防假绿），且不随 delta 线性增长。
    expect(LiveProcessCounters.appends, 200);
    expect(LiveProcessCounters.structuralChanges, 1,
        reason: '只有首个 delta 引起结构变化（键首次出现），其余只是文本增长');
    expect(LiveProcessCounters.pageBuilds, greaterThan(0), reason: '计数钩子不得恒 0');
    expect(LiveProcessCounters.processPlanBuilds, greaterThan(0));
    expect(LiveProcessCounters.provisionalRowBuilds, greaterThan(0));
    expect(LiveProcessCounters.pageBuilds, lessThanOrEqualTo(2),
        reason: '页面重建不得随 delta 增长');
    expect(LiveProcessCounters.processPlanBuilds, lessThanOrEqualTo(2),
        reason: '过程计划重建不得随 delta 增长');
    expect(
      LiveProcessCounters.provisionalRowBuilds,
      lessThanOrEqualTo(frames + 2),
      reason: '行级 ValueNotifier 每帧最多重建一次（与帧数同阶，而非 200 次）',
    );

    // 收起态：预览 = 最近一行（无换行 → 全文）且截断后总长 ≤120。
    final preview = latestReasoningLinePreview(fullText);
    expect(preview.length, lessThanOrEqualTo(120));
    expect(preview, '${fullText.substring(0, 119)}…');
    expect(find.text(preview), findsOneWidget);
    expect(find.text('思考中…'), findsOneWidget);

    // 展开态：正文完整包含最终全文（首尾片段），证明 200 个 delta 都进入了 UI。
    await tester.tap(find.byKey(_provisionalRowKey(1, 1)));
    await tester.pump();
    final bodyFinder = find.byKey(_provisionalBodyKey(1, 1));
    expect(bodyFinder, findsOneWidget);
    final selectable = tester.widget<SelectableText>(
      find.descendant(of: bodyFinder, matching: find.byType(SelectableText)),
    );
    expect(selectable.data, isNotNull);
    // 直接全等：200 个 delta 必须原样全部进入 UI（不是长度+抽样）。
    expect(selectable.data, fullText);
    expect(tester.takeException(), isNull);
    await _flushAppTimers(tester);
  });
}
