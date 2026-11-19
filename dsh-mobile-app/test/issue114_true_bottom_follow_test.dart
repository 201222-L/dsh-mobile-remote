// issue #114 task-11：维护者需求口径的 Widget 回归。
//
// 需求原话：
//   用户拉到最底部就钉在最底部，有新消息就滚动，对话消息始终钉在最底部。
//   如果用户上翻消息历史，则取消钉在最底部，有新消息就向下延长。
//   **必须真正到底才钉**（160px 只用于回底按钮显隐，不用于意图判定）。
//
// 覆盖：真正到底（含惯性）/ 距底未到底 / 上翻阅读 / 拖拽中来消息 / 内层滚动 /
// 程序性 ScrollEnd / 调度盲区（只 pump 1 帧断言生产已排帧）。

import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _session = 'session-114';
const double _designBottomInset = 6;

class _Backend {
  _Backend(this.history);
  final List<Map<String, dynamic>> history;
  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue114.test'
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

List<Map<String, dynamic>> _history({int tools = 10}) {
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
    'text': '帮我排查时间线滚动问题',
    'sourceKind': 'user',
  });
  add('assistant/message', {
    'turn': 1,
    'step': 1,
    'messageId': 'a0',
    'text': '',
    'reasoning': '先看一下当前布局',
    'reasoningChars': 8,
  });
  for (var i = 0; i < tools; i++) {
    add('tool/call', {
      'turn': 1,
      'step': 2 + i,
      'callId': 'c$i',
      'name': 'shell',
      'arguments': 'grep -n scroll lib/screens/chat_screen.dart | sed -n ${i}p',
    });
    add('tool/result', {
      'turn': 1,
      'step': 2 + i,
      'callId': 'c$i',
      'name': 'shell',
      'text': '第 $i 处命中的滚动代码行',
    });
  }
  add('assistant/message', {
    'turn': 1,
    'step': 2 + tools,
    'messageId': 'a-last',
    'text': '继续检查中……',
  });
  return events;
}

class _Probe {
  _Probe(this.tester)
    : _state = tester.state(find.byType(ChatScreen)),
      viewport = tester.renderObject<RenderBox>(find.byType(CustomScrollView));

  final WidgetTester tester;
  final dynamic _state;
  final RenderBox viewport;

  bool get intentFollow => _state.debugPinnedToBottom as bool;
  bool get dragging => _state.debugUserDragActive as bool;
  bool get pending => _state.debugFollowBottomScheduled as bool;
  bool get showJump => _state.debugShowJumpToLatest as bool;
  int get jumps => _state.debugFollowJumps as int;
  bool get frameScheduled => tester.binding.hasScheduledFrame;

  ScrollPosition get pos => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable, skipOffstage: false),
            )
            .first,
      )
      .position;

  double get distanceToEnd => pos.maxScrollExtent - pos.pixels;

  double? get tailResidual {
    final lists = find
        .byType(SliverList, skipOffstage: false)
        .evaluate()
        .toList()
        .reversed
        .toList();
    if (lists.isEmpty) return null;
    final sliver = lists.first.renderObject;
    if (sliver is! RenderSliverMultiBoxAdaptor) return null;
    RenderBox? child = sliver.firstChild;
    RenderBox? last;
    while (child != null) {
      last = child;
      child = sliver.childAfter(child);
    }
    if (last == null) return null;
    final rect = tester.getRect(find.byType(CustomScrollView));
    final origin = last.localToGlobal(Offset.zero);
    return (rect.bottom - _designBottomInset) - (origin.dy + last.size.height);
  }
}

Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  bool debug = false,
  Size size = const Size(390, 844),
  WorkStepDisplayMode mode = WorkStepDisplayMode.detailed,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode
    ..timelineDebug = debug;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: ChatScreen(
          key: ValueKey<String>('issue114-true-bottom-$debug'),
          store: store,
          apiClient: backend.api,
          onTitleChanged: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
  return store;
}

int _seq = 1000;

Future<void> _injectTool(
  WidgetTester tester,
  AppStore store, {
  int pumpFrames = 6,
}) async {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': {
      'seq': _seq++,
      'type': 'tool/call',
      'data': {
        'turn': 1,
        'step': 50,
        'callId': 'late-$_seq',
        'name': 'shell',
        'arguments': 'echo late',
      },
      'time': _seq * 10,
    },
  });
  for (var i = 0; i < pumpFrames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _injectReasoning(WidgetTester tester, AppStore store) async {
  store.injectFrame({
    'type': 'session/event',
    'sessionId': _session,
    'event': {
      'seq': _seq++,
      'type': 'assistant/live-chunk',
      'data': {
        'turn': 1,
        'step': 30,
        'reasoning': true,
        'text': '滚动分析：确认末端几何与意图。\n',
      },
      'time': _seq * 10,
    },
  });
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('需求1：拖到真正最底部松手（含惯性停稳）→ 钉住；新消息自动滚动', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);
    expect(probe.distanceToEnd.abs(), lessThanOrEqualTo(1));
    expect(probe.intentFollow, isTrue);

    // 先上翻进入阅读，再用带惯性的 fling 回到真正的底部。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(probe.intentFollow, isFalse, reason: '上翻后应为阅读态');

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -800),
      1600,
    );
    await tester.pumpAndSettle();
    expect(
      probe.distanceToEnd.abs(),
      lessThanOrEqualTo(1),
      reason: '惯性停稳后应真正到底',
    );
    expect(
      probe.intentFollow,
      isTrue,
      reason: '真正到底松手 → 钉住（ScrollEnd 已是惯性结束后的最终几何）',
    );

    // 来新消息 → 自动滚到底。
    await _injectTool(tester, store);
    expect(
      probe.tailResidual?.abs() ?? 999,
      lessThanOrEqualTo(2),
      reason: '钉住后新消息应自动贴底',
    );
    expect(probe.intentFollow, isTrue);
    await _flush(tester);
  });

  testWidgets('需求2：距底 >容差松手（未真正到底）→ 阅读态；新消息向下延长、不抢位置', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);

    // 向下拖 150px（距底约 130px，仍在 160 产品展示阈值内，但不是真正到底）。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 150));
    await tester.pump(const Duration(milliseconds: 300));
    final readingPixels = probe.pos.pixels;
    final readingDistance = probe.distanceToEnd;
    expect(
      readingDistance,
      greaterThan(1),
      reason: '用例前提：必须停在真正的底部之上（实测 $readingDistance）',
    );
    expect(
      readingDistance,
      lessThanOrEqualTo(160),
      reason: '用例前提：落在 160px 产品展示阈值内（用于验证死角修复）',
    );
    expect(probe.intentFollow, isFalse, reason: '真正到底才钉：130px 不是底部 → 阅读态');
    // 注意：按钮显隐仍是既有 160px 产品阈值（本任务不改）；该场景按钮隐藏，
    // 属已知死角，已在 task-11 汇报中提交产品决策。

    // 新消息：不滚动、内容向下延长。
    final tailBefore = probe.tailResidual;
    final jumpsBefore = probe.jumps;
    await _injectTool(tester, store);
    expect(
      probe.pos.pixels,
      closeTo(readingPixels, 1),
      reason: '阅读态下新消息不得移动视口',
    );
    expect(probe.intentFollow, isFalse, reason: '阅读态不得被新消息改写为跟随');
    expect(probe.jumps, jumpsBefore, reason: '阅读态不得执行任何自动校正');
    expect(
      (probe.tailResidual ?? 0),
      lessThanOrEqualTo((tailBefore ?? 0) + 1),
      reason: '新消息应向视口下方延长（tail 残差更负）',
    );
    await _flush(tester);
  });

  testWidgets('需求3：上翻到中间 → 来新消息保持阅读位置不跳', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 420));
    await tester.pump(const Duration(milliseconds: 300));
    expect(probe.intentFollow, isFalse);
    final pixels = probe.pos.pixels;
    final jumpsBefore = probe.jumps;

    await _injectTool(tester, store);
    expect(probe.pos.pixels, closeTo(pixels, 1), reason: '上翻阅读后新消息不得把视口拉走');
    expect(probe.jumps, jumpsBefore);
    expect(probe.intentFollow, isFalse);
    await _flush(tester);
  });

  testWidgets('需求4：手指仍按着时来新消息 → 不改意图、不被拉走、不排校正', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await gesture.moveBy(const Offset(0, 24));
    await gesture.moveBy(const Offset(0, 96));
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.dragging, isTrue);
    final pixels = probe.pos.pixels;
    final jumpsBefore = probe.jumps;

    store.injectFrame({
      'type': 'session/event',
      'sessionId': _session,
      'event': {
        'seq': _seq++,
        'type': 'tool/call',
        'data': {
          'turn': 1,
          'step': 50,
          'callId': 'during-drag',
          'name': 'shell',
          'arguments': 'echo during',
        },
        'time': _seq * 10,
      },
    });
    expect(probe.pending, isFalse, reason: '拖拽中不得排队自动校正（用户手势优先）');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.pos.pixels, closeTo(pixels, 1), reason: '拖拽中来消息不得移动视口');
    expect(probe.jumps, jumpsBefore);
    expect(probe.dragging, isTrue);
    await gesture.up();
    await _flush(tester);
  });

  testWidgets('生命周期：距底 150px 处 fling 向底部 → 惯性停稳在底部 → 钉住', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 150));
    await tester.pump(const Duration(milliseconds: 200));
    expect(probe.intentFollow, isFalse);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -500),
      1400,
    );
    await tester.pumpAndSettle();
    expect(
      probe.distanceToEnd.abs(),
      lessThanOrEqualTo(1),
      reason: '惯性应把视口带到真正的底部',
    );
    expect(
      probe.intentFollow,
      isTrue,
      reason: 'ScrollEnd 的几何是惯性停稳后的最终几何；不得被判成阅读且无第二次机会',
    );

    await _injectTool(tester, store);
    expect(probe.tailResidual?.abs() ?? 999, lessThanOrEqualTo(2));
    await _flush(tester);
  });

  testWidgets('程序性移动离开末端 → 进入阅读；已排队校正不得把视口抢回', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);
    expect(probe.intentFollow, isTrue);

    // 先制造一个已排队的跟随校正（内容增长请求），再在它执行前把视口程序性移离末端。
    await _injectReasoning(tester, store);
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.pending, isTrue, reason: '用例前提：已有待执行校正');
    final jumpsBefore = probe.jumps;

    // 直接改 ScrollPosition（未包 begin/endProgrammaticScroll）：模拟外部程序性移动。
    probe.pos.jumpTo(probe.pos.maxScrollExtent - 300);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.intentFollow, isFalse, reason: '程序性滚动把视口移离末端 → 阅读态');
    expect(probe.pending, isFalse, reason: '已排队校正必须被阅读态作废');
    expect(
      probe.pos.pixels,
      closeTo(probe.pos.maxScrollExtent - 300, 1),
      reason: '阅读态不得被自动校正拉回',
    );
    expect(probe.jumps, jumpsBefore, reason: '作废后不得执行校正');
    await _flush(tester);
  });

  testWidgets('程序性跳到末端不得冒充“用户回底”：阅读态保持，只有用户动作恢复', (tester) async {
    await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);

    // 用户上翻进入阅读。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(probe.intentFollow, isFalse);
    final readingPixels = probe.pos.pixels;

    // 程序性直接跳到末端（不是用户手势、也不是显式回底按钮）。
    probe.pos.jumpTo(probe.pos.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.pos.pixels, closeTo(probe.pos.maxScrollExtent, 1));
    expect(
      probe.intentFollow,
      isFalse,
      reason: '程序性 ScrollEnd 不得被当成用户“主动滚回底部”而恢复跟随',
    );

    // 真正的用户回底（拖到末端松手）才恢复跟随。
    await tester.drag(
      find.byType(CustomScrollView),
      Offset(0, -(probe.pos.pixels - 0) - 50),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(probe.pos.pixels, greaterThan(readingPixels));
    expect(probe.intentFollow, isTrue, reason: '用户手势真正到底 → 钉住');
    await _flush(tester);
  });

  testWidgets('调度契约：owner 的 ensureFrame 在生产实现里必须自己调度一帧', (tester) async {
    await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);
    // 收敛后不应有排队帧；随后触发生产实现里的 ensureFrame，必须同步把帧排上。
    expect(probe.frameScheduled, isFalse);
    final state = tester.state(find.byType(ChatScreen)) as dynamic;
    state.debugEnsureScrollFollowFrame();
    expect(
      probe.frameScheduled,
      isTrue,
      reason: 'addPostFrameCallback 不调度帧；ensureFrame 必须 ensureVisualUpdate/scheduleFrame',
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.frameScheduled, isFalse, reason: '执行完一帧后不得自激');
    await _flush(tester);
  });

  testWidgets('内层 SingleChildScrollView 拖动不得改写主列表意图（depth 过滤）', (tester) async {
    // 短会话 + 一条很长的 plugin 注入消息（debug 模式渲染为可展开卡片）。展开后卡片
    // 内部有 maxHeight=260 的 SingleChildScrollView；在内部拖动会冒泡 Scroll 通知。
    final longInjected = List.generate(
      80,
      (i) => '注入正文第 $i 行，用于验证内层滚动。',
    ).join('\n');
    final events = <Map<String, dynamic>>[
      {
        'seq': 1,
        'type': 'turn/start',
        'data': {'turn': 1},
      },
      {
        'seq': 2,
        'type': 'user/message',
        'data': {'messageId': 'u1', 'text': '普通问题', 'sourceKind': 'user'},
      },
      {
        'seq': 3,
        'type': 'user/message',
        'data': {
          'messageId': 'inj1',
          'text': longInjected,
          'sourceKind': 'plugin',
        },
      },
      {
        'seq': 4,
        'type': 'assistant/message',
        'data': {'turn': 1, 'step': 1, 'messageId': 'a1', 'text': '答复'},
      },
    ];
    await _mount(tester, _Backend(events), debug: true);
    final probe = _Probe(tester);
    await _flush(tester);
    expect(probe.intentFollow, isTrue);

    // 展开注入卡片：点标题行（插件注入）。
    final header = find.textContaining('插件注入');
    expect(header, findsOneWidget, reason: 'debug 模式应渲染注入折叠块');
    await tester.tap(
      find.ancestor(of: header, matching: find.byType(InkWell)).first,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final inner = find.ancestor(
      of: find.text(longInjected),
      matching: find.byType(SingleChildScrollView),
    );
    expect(inner, findsOneWidget, reason: '展开后应出现内层滚动视区');
    // 把内层视区滚进可见区域（测试侧 ensureVisible；主列表 intent 不因此改变）。
    await tester.ensureVisible(inner.first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final mainPixels = probe.pos.pixels;
    final mainJumps = probe.jumps;
    // 在内层拖动（不会触底，几何与主列表无关）。
    await tester.drag(inner.first, const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(probe.intentFollow, isTrue, reason: '用户只滚了内层内容，主对话不得取消钉底');
    expect(probe.pos.pixels, closeTo(mainPixels, 1), reason: '内层滚动不得移动主列表');
    expect(probe.jumps, mainJumps, reason: '内层滚动不得触发主列表校正');
    expect(probe.showJump, isFalse, reason: '内层 metrics 不得污染主列表派生展示（近底/按钮）');
    await _flush(tester);
  });

  testWidgets('调度盲区：内容增长后只 pump 1 帧，生产必须已排上帧', (tester) async {
    final store = await _mount(tester, _Backend(_history()), debug: false);
    final probe = _Probe(tester);
    await _flush(tester);
    final jumpsBefore = probe.jumps;

    // 注入结构性思考增量（同条目内部增高；不直接调用回底）。
    await _injectReasoning(tester, store);
    // 只 pump 一帧建立状态，之后**不再由测试提供帧源**。
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      probe.frameScheduled,
      isTrue,
      reason: '生产必须自己保证「布局后校正」的下一帧（addPostFrameCallback 不调度帧）',
    );
    expect(probe.pending, isTrue, reason: '校正应已排队/执行并进入布局后复核');
    expect(probe.jumps, greaterThan(jumpsBefore), reason: '增长帧的校正应在这一帧执行');

    // 再 pump 一帧：布局后复核应收敛。
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      probe.tailResidual?.abs() ?? 999,
      lessThanOrEqualTo(2),
      reason: '两帧内真实末端应贴合设计底边',
    );
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.frameScheduled, isFalse, reason: '收敛后不得有空闲帧自激');
    await _flush(tester);
  });
}
