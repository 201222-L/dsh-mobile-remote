// issue #123 审查 P2（第 2 项）：partial 段补页后**段/组折叠键从 head 变边界**，
// 用户手动点过的折叠状态丢失。
//
// 审查报告描述（外部 widget 探针，按描述重建）：
//   - 初始 REST 只返回 partial 窗口（缺 turn/start 与开段插话）→ `boundarySeq=null`
//     → 段键 `1:head`、组键 `1:head:<step>`；
//   - 用户真实点击某个 step 的组抬头，把组收起（手动状态写入 head 键）；
//   - 用户真实上翻，before 分页补入 `turn/start seq1` + `插话 seq3` → 同一批过程行
//     现在有了真实开段边界 → 段键变 `1:3`、组键变 `1:3:<step>` → 手动状态失配；
//   - 期望：同一段/组的手动折叠状态跟着迁移，组保持收起；实际：回到档位默认（展开）。
//
// 第二个用例（#123 复核 blocking）：**工具行的身份不能用 seq**。
// 同一工具先见 `tool/result`（seq110）→ `reportedSeq=110`；补页补入 `tool/call`
// （seq100）会无条件覆盖成 100（call 是权威 layout 位置）。迁移若按行 seq 求交，
// 同一行看起来是两行 → 段匹配失败 → 手动状态被删。身份必须是 durable 的 callId。
//
// 断言口径（不使用键字符串断言替代点击行为）：
//   1. 点击前用**几何**（组抬头 ↔ 行标记的上下相邻）定位目标组抬头；
//   2. 点击后该组的行标记消失（组真的收起了）；
//   3. 补页后该组的行标记**仍然消失**（手动状态保持），并且再点一次能展开并
//      出现「第 35 步」行标记 —— 用点击行为证明这一组确实是 step35，而不是靠键名。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue123_p2_partial_segment_state_test.dart

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

const _session = 'session-123-p2';
const Size _surface = Size(390, 844);

/// 目标组所在 step（窗口内、补页后仍在分批窗口前 50 行内）。
const int _targetStep = 35;

String get _marker => '第 $_targetStep 步 · 过程段标记';

/// 单轮长过程 + 轮内插话：turn1(head: prompt/插话之后) → steps 1..40（各 1 条思考行）
/// → 末条 assistant 消息（作为过程块宿主，保证窗口里有可锚定的时间线条目）。
///
/// 事件序：seq1 turn/start / seq2 prompt / seq3 插话 / seq4..43 steps1..40 /
/// seq44 assistant 回答。初始窗口只给最后 10 条（seq35..44）：**缺 turn/start、
/// 缺插话 seq3** → 过程段只能拿到 `head` 哨兵。
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
    'text': '先看滚动问题',
    'sourceKind': 'user',
  });
  add('user/message', {
    'messageId': 'u2',
    'text': '插一句：先别动底部',
    'sourceKind': 'user',
  });
  for (var step = 1; step <= 40; step++) {
    add('assistant/message', {
      'turn': 1,
      'step': step,
      'messageId': 'r1-$step',
      'text': '',
      'reasoning': step == _targetStep ? _marker : '第 $step 步：检查状态',
      'reasoningChars': 18,
    });
  }
  add('assistant/message', {
    'turn': 1,
    'step': 41,
    'messageId': 'a1',
    'text': '检查中……',
  });
  return events;
}

/// 工具行夹具（#123 复核 blocking）：初始窗口只有 result，没有 call。
///
/// seq1 turn/start / seq2 提示词 / seq3 插话 / seq4..6 三个 tool/call /
/// seq7 result cC / seq8 result cA / seq9 result cB / seq10 思考行（把轮次带起来）/
/// seq11 回答（过程块宿主）。
/// 初始窗口 = 最后 5 条（seq7..11）：cA/cB/cC 都只有 result（seq 8/9/7），
/// call 全在补页里。补页 seq1..6 一次带回**开段边界(3) + 三个 call** →
/// cA 8→4、cB 9→5、cC 7→6，与边界变化发生在同一次 sync。
List<Map<String, dynamic>> _toolHistory() {
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
    'text': '先看滚动问题',
    'sourceKind': 'user',
  });
  add('user/message', {
    'messageId': 'u2',
    'text': '插一句：先别动底部',
    'sourceKind': 'user',
  });
  add('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'cA',
    'name': 'shell-A',
    'arguments': 'echo A',
  });
  add('tool/call', {
    'turn': 1,
    'step': 1,
    'callId': 'cB',
    'name': 'shell-B',
    'arguments': 'echo B',
  });
  add('tool/call', {
    'turn': 1,
    'step': 2,
    'callId': 'cC',
    'name': 'shell-C',
    'arguments': 'echo C',
  });
  add('tool/result', {
    'turn': 1,
    'step': 2,
    'callId': 'cC',
    'name': 'shell-C',
    'text': 'ok C',
  });
  add('tool/result', {
    'turn': 1,
    'step': 1,
    'callId': 'cA',
    'name': 'shell-A',
    'text': 'ok A',
  });
  add('tool/result', {
    'turn': 1,
    'step': 1,
    'callId': 'cB',
    'name': 'shell-B',
    'text': 'ok B',
  });
  add('assistant/message', {
    'turn': 1,
    'step': 3,
    'messageId': 'r1',
    'text': '',
    'reasoning': '第 3 步：检查状态',
    'reasoningChars': 9,
  });
  add('assistant/message', {
    'turn': 1,
    'step': 4,
    'messageId': 'a1',
    'text': '检查中……',
  });
  return events;
}

/// v3 夹具 A（#123 第三轮）：**段键不变、只有 step 迟到**。
///
/// seq1 turn/start / seq2 提示词 / seq3 tool/call cC(step35) / seq4 tool/result cC（**无 step**）/
/// seq5 思考行 step1 / seq6 回答（过程块宿主）。
/// 初始窗口 = 最后 3 条（seq4..6）：段键 `1:head`（无插话边界），工具组键 `1:head:x`；
/// 补页 seq1..3 只补入 call(step35) 与 turn/start：**段键仍是 `1:head`**，
/// 组键变 `1:head:35`。当前实现只在段键集合变化时才迁移 → 这条路径完全没覆盖。
List<Map<String, dynamic>> _noStepHistory({required bool withInterjection}) {
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
    'text': '先看滚动问题',
    'sourceKind': 'user',
  });
  if (withInterjection) {
    add('user/message', {
      'messageId': 'u2',
      'text': '插一句：先别动底部',
      'sourceKind': 'user',
    });
  }
  add('tool/call', {
    'turn': 1,
    'step': 35,
    'callId': 'cC',
    'name': 'shell-C',
    'arguments': 'echo C',
  });
  // 缺 step 的 result：工具组初始键是 `...:x`。
  add('tool/result', {
    'turn': 1,
    'callId': 'cC',
    'name': 'shell-C',
    'text': 'ok C',
  });
  add('assistant/message', {
    'turn': 1,
    'step': 1,
    'messageId': 'r1',
    'text': '',
    'reasoning': '想一下：检查状态',
    'reasoningChars': 9,
  });
  add('assistant/message', {
    'turn': 1,
    'step': 2,
    'messageId': 'a1',
    'text': '检查中……',
  });
  return events;
}

class _Backend {
  _Backend(this.history, {required this.initialLimit});

  final List<Map<String, dynamic>> history;

  /// 首次加载只返回最后 N 条（真实服务端窗口），更早由 before 分页取回。
  final int initialLimit;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue123-p2.test'
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
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('before')) {
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        final preceding = history
            .where((e) => (e['seq'] as int) < before)
            .toList();
        body = {
          'ok': true,
          'events': preceding.length > limit
              ? preceding.sublist(preceding.length - limit)
              : preceding,
          'hasMore': preceding.length > limit,
        };
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else {
        body = {
          'ok': true,
          'events': history.length > initialLimit
              ? history.sublist(history.length - initialLimit)
              : history,
          'hasMore': history.length > initialLimit,
        };
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

Finder get _groupHeaders => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_ProcessGroupHeader',
);

int _headerCount(WidgetTester tester) => _groupHeaders.evaluate().length;

/// 点组抬头（方案 D 后 widget 含组内行，用抬头自己的 InkWell 定位点击区）。
Future<void> _tapHeader(WidgetTester tester, int index) async {
  await tester.tap(
    find
        .descendant(of: _groupHeaders.at(index), matching: find.byType(InkWell))
        .first,
  );
  await tester.pump(const Duration(milliseconds: 120));
}

bool _headerExpanded(WidgetTester tester, int index) {
  // issue #123（方案 D）：展开状态在 `_ProcessGroupHeader` 的 State 上。
  final state = tester.state(_groupHeaders.at(index));
  // 内部组件，靠 dynamic 读 debugExpanded（与 #122 widget 测试同一口径）。
  // ignore: avoid_dynamic_calls
  return (state as dynamic).debugExpanded as bool;
}

Rect _rectOf(WidgetTester tester, Finder finder) => tester.getRect(finder);

/// 用几何定位「行标记所在的组抬头」：比标记靠上、且底边最接近的那个组抬头。
int _headerIndexAboveMarker(WidgetTester tester, String marker) {
  final markerRect = _rectOf(tester, find.textContaining(marker).first);
  var bestIndex = -1;
  var bestBottom = double.negativeInfinity;
  final count = _headerCount(tester);
  for (var i = 0; i < count; i++) {
    final rect = _rectOf(tester, _groupHeaders.at(i));
    if (rect.top < markerRect.top && rect.bottom > bestBottom) {
      bestBottom = rect.bottom;
      bestIndex = i;
    }
  }
  expect(bestIndex, greaterThanOrEqualTo(0), reason: '必须能定位到行标记所属的组抬头');
  return bestIndex;
}

/// 主滚动列表的真实 `minScrollExtent`（<0 = center 之前已有更早历史项）。
double _minExtent(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable, skipOffstage: false),
          )
          .first,
    )
    .position
    .minScrollExtent;

/// 真实上翻手势（多步 pan；单事件位移在 SelectionArea + lazy 列表下会被吞掉）。
Future<void> _dragUp(WidgetTester tester, double distance) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(CustomScrollView)),
  );
  await tester.pump(const Duration(milliseconds: 20));
  const step = 45.0;
  var moved = 0.0;
  while (moved < distance) {
    await gesture.moveBy(const Offset(0, step));
    moved += step;
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.detailed,
  String suffix = '',
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode
    ..turnFoldTiming = TurnFoldTiming.afterAnswer;
  await tester.binding.setSurfaceSize(_surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() async {
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: const MediaQueryData(size: _surface),
          child: ChatScreen(
            key: ValueKey<String>('issue123-p2$suffix'),
            store: store,
            apiClient: backend.api,
            onTitleChanged: () {},
            autoFillFirstScreen: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('P2 partial 窗口补入开段边界后，用户手动收起的组必须保持收起', (tester) async {
    final backend = _Backend(_history(), initialLimit: 10);
    await _mount(tester, backend);
    final replay = <String>[];

    // ── 1. 初始 partial 窗口：只有 steps 32..40 的组，且目标组可用几何定位 ──
    final initialHeaders = _headerCount(tester);
    // ignore: avoid_print
    print(
      '[123-P2] mount headers=$initialHeaders '
      'marker=${find.textContaining(_marker).evaluate().length}',
    );
    expect(
      initialHeaders,
      greaterThanOrEqualTo(9),
      reason: '初始窗口应只含末尾若干 step 的组（partial 窗口）',
    );
    expect(find.textContaining(_marker), findsOneWidget, reason: '目标行初始应可见');
    final targetIndex = _headerIndexAboveMarker(tester, _marker);
    expect(
      _headerExpanded(tester, targetIndex),
      isTrue,
      reason: '详细档运行中组默认展开（点击前的前提）',
    );

    // ── 2. 真实点击组抬头：手动收起 ───────────────────────────────────────
    await _tapHeader(tester, targetIndex);
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(
      '[123-P2] afterTap headers=${_headerCount(tester)} '
      'marker=${find.textContaining(_marker).evaluate().length} '
      'expanded=${_headerExpanded(tester, targetIndex)}',
    );
    expect(_headerExpanded(tester, targetIndex), isFalse, reason: '点击组抬头应手动收起');
    expect(find.textContaining(_marker), findsNothing, reason: '组收起后组内行不应再渲染');
    replay.add('手动收起 step$_targetStep');

    // ── 3. 真实上翻：before 分页把 turn/start 与插话边界补进来 ────────────
    for (var page = 0; page < 3; page++) {
      await _dragUp(tester, 540);
    }
    // ignore: avoid_print
    print(
      '[123-P2] afterPaging headers=${_headerCount(tester)} '
      'marker=${find.textContaining(_marker).evaluate().length}',
    );
    expect(
      _headerCount(tester),
      greaterThan(initialHeaders),
      reason: '上翻应补入更早的 step 组（真实分页），当前 headers=${_headerCount(tester)}',
    );

    // ── 4. 手动状态必须保持：step35 的组仍然收起 ─────────────────────────
    // 补页后 turn 有 40 个 step 组（steps1..40），step35 是第 35 个组（索引 34）。
    final targetAfter = _targetStep - 1;
    expect(
      _headerExpanded(tester, targetAfter),
      isFalse,
      reason:
          '补入开段边界后，同一组的手动收起状态必须保持'
          '（旧实现按 head 键写入、按边界键读取 → 弹回默认展开）',
    );
    expect(
      find.textContaining(_marker),
      findsNothing,
      reason: '补页后组保持收起，组内行不应出现',
    );
    replay.add('补页后保持收起');

    // ── 5. 行为身份校验：再点一次 → 展开，并出现 step35 的行标记 ──────────
    await tester.ensureVisible(_groupHeaders.at(targetAfter));
    await tester.pumpAndSettle();
    await _tapHeader(tester, targetAfter);
    await tester.pumpAndSettle();
    expect(
      _headerExpanded(tester, targetAfter),
      isTrue,
      reason: '同一组抬头再次点击应展开（证明点击行为可往返）',
    );
    expect(
      find.textContaining(_marker),
      findsOneWidget,
      reason: '索引 34 的组必须就是 step$_targetStep 的组（展开后能看到该行标记）',
    );
    replay.add('再次点击可展开');

    expect(tester.takeException(), isNull);
    // ignore: avoid_print
    print('[123-P2] PASS steps=$replay');
  });

  // #123 复核（blocking）：迁移身份必须是 durable 的 callId，不是行 seq。
  //
  // partial 窗口只有 `tool/result` → 工具行 seq 由 result 决定；补页把 `tool/call`
  // 和开段边界**同页**带回来时，`reportedSeq` 被 call 覆盖（8/9/7 → 4/5/6）。
  // 按 seq 求交只剩 1/4（只有思考行不变），低于阈值 → 段匹配失败 → 手动状态被删；
  // 按 callId 求交是 4/4 → 状态保持。
  testWidgets('P2b 工具行 seq 被 call 覆盖时，手动收起的组仍必须保持收起', (tester) async {
    final backend = _Backend(_toolHistory(), initialLimit: 5);
    await _mount(tester, backend, suffix: '-p2b');

    // ── 1. 初始 partial 窗口：三组默认展开，工具卡可见 ──────────────────
    expect(_headerCount(tester), 3, reason: '窗口内应有 step1/step2/step3 三组');
    expect(find.textContaining('shell-A'), findsOneWidget);
    expect(find.textContaining('shell-B'), findsOneWidget);
    expect(find.textContaining('shell-C'), findsOneWidget);
    final targetIndex = _headerIndexAboveMarker(tester, 'shell-C');
    expect(
      _headerExpanded(tester, targetIndex),
      isTrue,
      reason: '详细档运行中组默认展开（点击前的前提）',
    );

    // ── 2. 真实点击：手动收起 cC 的组 ──────────────────────────────────
    await _tapHeader(tester, targetIndex);
    await tester.pumpAndSettle();
    expect(_headerExpanded(tester, targetIndex), isFalse);
    expect(
      find.textContaining('shell-C'),
      findsNothing,
      reason: '组收起后组内工具卡不应渲染',
    );
    expect(
      find.textContaining('shell-A'),
      findsOneWidget,
      reason: '其它组仍是默认展开（对照）',
    );

    // ── 3. 真实上翻：同一页补回三个 call + 开段边界 ────────────────────
    // 空 older sliver 自带 10dp 顶部内边距（min≈-10），所以用「上翻前后 min 变负很多」
    // 作为「真的补进了更早历史」的判据。
    final minBefore = _minExtent(tester);
    await _dragUp(tester, 540);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // ignore: avoid_print
    print(
      '[123-P2b] afterPaging headers=${_headerCount(tester)} '
      'min=${_minExtent(tester)} '
      'A=${find.textContaining('shell-A').evaluate().length} '
      'B=${find.textContaining('shell-B').evaluate().length} '
      'C=${find.textContaining('shell-C').evaluate().length}',
    );
    expect(
      _minExtent(tester),
      lessThan(minBefore - 20),
      reason:
          '前提：这次上翻真的把更早历史补进了 center 之前'
          '（min $minBefore → ${_minExtent(tester)}）',
    );

    // ── 4. 手动状态必须保持：cC 的组仍然收起，其它组仍展开 ────────────
    expect(_headerCount(tester), 3, reason: '补页后仍是同一段的三组（段键从 head 变成边界，组数不变）');
    expect(
      find.textContaining('shell-A'),
      findsOneWidget,
      reason: '其它组按默认展开，说明过程块仍在正常渲染',
    );
    expect(find.textContaining('shell-B'), findsOneWidget);
    expect(
      find.textContaining('shell-C'),
      findsNothing,
      reason:
          '补入开段边界 + call 覆盖 seq 后，同一组的手动收起状态必须保持'
          '（按 seq 求交会匹配失败 → 弹回默认展开）',
    );
    expect(tester.takeException(), isNull);
  });

  // ── v3：段键不变、只有 step 迟到（null→35） ───────────────────────────
  //
  // 组键从 `1:head:x` 变 `1:head:35`，但**段键集合没变**；旧实现只在段键集合
  // 变化时调用迁移 → 这条路径完全没覆盖（reviewer-11 实证：期望 false，实际 null）。
  testWidgets('P2c 段键不变、只有 step 迟到（null→35）：手动收起的组仍必须保持收起', (tester) async {
    final backend = _Backend(
      _noStepHistory(withInterjection: false),
      initialLimit: 3,
    );
    await _mount(tester, backend, suffix: '-p2c');

    expect(_headerCount(tester), 2, reason: '初始：无 step 工具组 + step1 思考组');
    expect(find.textContaining('shell-C'), findsOneWidget);
    expect(find.textContaining('想一下：检查状态'), findsOneWidget);
    final targetIndex = _headerIndexAboveMarker(tester, 'shell-C');

    // 真实点击：收起无 step 的工具组。
    await _tapHeader(tester, targetIndex);
    await tester.pumpAndSettle();
    expect(_headerExpanded(tester, targetIndex), isFalse);
    expect(find.textContaining('shell-C'), findsNothing);

    // 真实上翻：补页只补入 call(step35) + turn/start（无插话 → 段键不变）。
    final minBefore = _minExtent(tester);
    await _dragUp(tester, 540);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // ignore: avoid_print
    print(
      '[123-P2c] afterPaging headers=${_headerCount(tester)} '
      'min=${_minExtent(tester)} '
      'C=${find.textContaining('shell-C').evaluate().length} '
      'think=${find.textContaining('想一下：检查状态').evaluate().length}',
    );
    expect(
      _minExtent(tester),
      lessThan(minBefore - 20),
      reason: '前提：这次上翻真的补进了更早历史',
    );
    expect(_headerCount(tester), 2, reason: '仅 step 迟到，组数不变');
    expect(
      find.textContaining('想一下：检查状态'),
      findsOneWidget,
      reason: '对照：另一组仍按档位默认展开',
    );
    expect(
      find.textContaining('shell-C'),
      findsNothing,
      reason:
          'step 从 null 变 35 后，同一组的手动收起状态必须保持'
          '（段键没变，旧实现不触发迁移 → 弹回默认展开）',
    );
    expect(tester.takeException(), isNull);
  });

  // ── v3：段键变化 + step 迟到（null→35） ──────────────────────────────
  //
  // 补页同页带回插话边界 + call(step35)：段键 `1:head`→`1:3`，组键
  // `1:head:x`→`1:3:35`。旧 `_migrateSegment` 按 step 值搬组状态，
  // `to.steps.contains(null)` 为 false → 组状态丢失。
  testWidgets('P2d 段键变化 + step 迟到（null→35）：手动收起的组仍必须保持收起', (tester) async {
    final backend = _Backend(
      _noStepHistory(withInterjection: true),
      initialLimit: 3,
    );
    await _mount(tester, backend, suffix: '-p2d');

    expect(_headerCount(tester), 2);
    expect(find.textContaining('shell-C'), findsOneWidget);
    final targetIndex = _headerIndexAboveMarker(tester, 'shell-C');
    await _tapHeader(tester, targetIndex);
    await tester.pumpAndSettle();
    expect(find.textContaining('shell-C'), findsNothing);

    // 真实上翻：同一页补入边界(3) + call(step35) + turn/start。
    final minBefore = _minExtent(tester);
    await _dragUp(tester, 540);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // ignore: avoid_print
    print(
      '[123-P2d] afterPaging headers=${_headerCount(tester)} '
      'min=${_minExtent(tester)} '
      'C=${find.textContaining('shell-C').evaluate().length} '
      'think=${find.textContaining('想一下：检查状态').evaluate().length}',
    );
    expect(
      _minExtent(tester),
      lessThan(minBefore - 20),
      reason: '前提：这次上翻真的补进了更早历史',
    );
    expect(_headerCount(tester), 2);
    expect(
      find.textContaining('想一下：检查状态'),
      findsOneWidget,
      reason: '对照：step1 思考组按默认展开',
    );
    expect(
      find.textContaining('shell-C'),
      findsNothing,
      reason: '段键与 step 同时变化时，组的手动收起状态也必须保持',
    );
    expect(tester.takeException(), isNull);
  });
}
