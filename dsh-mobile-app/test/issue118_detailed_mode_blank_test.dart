// issue #118 复现（条件对齐维护者截图）：详细档 + 单轮 >50 过程行 + 运行中。
//
// 背景：rc.2 已修「SSE 事件改布局后不跟随时停住」的**已证实部分**；截图里的
// 「内容下方大段空白 + 实心回底按钮」一直没能复现。维护者 2026-11-17 的新线索：
// 截图里同时出现**组抬头**与**「显示更多（还有 54 行）」**，因此复现条件固定为
// `WorkStepDisplayMode.detailed`（组抬头默认展开、组内行可见）+ 单轮 > 50 过程行
// （触发 `processBatchSize = 50` 分批）+ 运行中（活动条/停止按钮），
// 再插入会改变布局的事件（`todo/write`、`session/jobs`）。
//
// ⚠️ 2026-11-17 复核实测（本文件记录）：
// 1. **详细档 + 104 行 + 运行中**下，mount / todo-write×3 / session-jobs / 越过分批
//    边界 / SSE 突发 / 1.5x / 多轮长会话 / turn-end→新轮，全部**未出现正 tailResidual**
//    （每次尝试的实测值见 `[118]` stdout 行与各用例注释）。方向只有负残差（内容被裁），
//    且都在 8 帧验收窗口内收敛（首帧瞬时负残差最大 -260dp，见尝试H）。
// 2. 把截图本地裁切放大后核对：**组抬头右侧 chevron 朝下**（`_ProcessGroupHeader`
//    expanded=false），抬头之间**没有组内行** → 截图是**折叠组**（标准档 / 详细档的
//    已完成组），不是详细档的「默认展开」。另外「显示更多」行由 50 行分批独立产生，
//    标准档同样会出现——它并不能唯一推出详细档。
// 3. **现象本身已复现**（尝试M，持续多帧）：`tailResidual=+526`（内容下方 526dp
//    空白）+ 回底按钮可见。触发条件不是「运行中插入事件」，而是：
//    固定 50 条初始窗口的长会话 → 用户上翻加载过更早历史（`paged=true`，
//    `chat_screen.dart:1204` 的 `_olderItems.isNotEmpty`；`:1234-1235` 的
//    `shortEnough = !paged && ...` 对 paged **永久停用** #77 短内容底部占位）→
//    标准档本轮 `turn/end` 自动折叠成摘要（内容矮于视口）→
//    用户回滑停在离底 40px（阅读态）⇒ 内容顶对齐、下方大段空白、回底按钮常显。
//    典型几何：`gap=0`、`max=0`、`dist=40`、`intent=reading`、`showJump=true`。
//
// 本文件只做**回放测量**，不改产品代码、不复制生产滚动算法：
// - `intent` / `showJumpToLatest` / `gap` / `jumps` 取 ChatScreen 只读诊断；
// - `tailResidual` 取真实 live SliverList 的**最后投影子项** RenderObject，
//   与 viewport 同一坐标系，扣掉设计底部内边距（6px）；**正 = 内容下方还有空白**；
// - 额外测量：`maxScrollExtent` vs 实际内容末端（`ghost`）、`projectionEndIndex` vs
//   已构建最后子项、`显示更多` 行的实际高度/位置、回底按钮可见性、组抬头个数；
// - 一次 pumpWidget 挂载，后续全部通过 store.injectFrame 注入；不卸载重挂；
// - 不使用 tester.ensureVisible / jumpTo / 先点回底来掩盖状态。
//
// 用例分工：
// - 基线/A–J、对照1/2：断言**期望行为**（真实末端贴合设计底边、跟随态无回底按钮）；
//   绿 = 未复现（当前实际结果）。
// - 尝试D：记录一个方向相反的已知缺口（展开任务面板让视口变矮 90px 后不跟随）；
// - 尝试M：**复现用例**，断言截图现象本身（正 tailResidual + 回底按钮可见）。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue118_detailed_mode_blank_test.dart

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

const _session = 'session-118-detailed';

/// live 列表 SliverPadding 的底部内边距（chat_screen.dart `_buildLiveView`）。
const double _designBottomInset = 6;

/// 与截图对齐的夹具：52 个 step × （1 条思考行 + 1 次工具调用）= **104 个过程行**。
/// 前 50 行可见（25 个组抬头），「显示更多（还有 54 行）」——与截图文案一致。
const int _fixtureSteps = 52;

class _Backend {
  _Backend(this.history, {this.initialLimit});

  final List<Map<String, dynamic>> history;

  /// 非空时：首次加载只返回**最后 N 条**事件（真实服务端窗口），更早的事件
  /// 由 `before` 分页取回——用于回放「用户上翻加载过更早历史」的 `paged` 状态。
  final int? initialLimit;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue118-detailed.test'
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
        final preceding =
            history.where((e) => (e['seq'] as int) < before).toList();
        body = {
          'ok': true,
          'events': preceding.length > limit
              ? preceding.sublist(preceding.length - limit)
              : preceding,
          'hasMore': preceding.length > limit,
        };
      } else if (params.containsKey('after')) {
        body = {'ok': true, 'events': <Object>[], 'hasMore': false};
      } else if (initialLimit == null) {
        // 默认：返回完整历史（模拟「长会话已通过 catch-up/上翻加载完」）。
        body = {'ok': true, 'events': history, 'hasMore': false};
      } else {
        // 分页窗口模式：首次只给最后 N 条，更早由 before 取回。
        final window = initialLimit!;
        body = {
          'ok': true,
          'events': history.length > window
              ? history.sublist(history.length - window)
              : history,
          'hasMore': history.length > window,
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

/// 运行中（无 turn/end）的单轮快照：
/// turn/start + 提问 + [steps] 个 step（每条思考 + 一次工具 call/result）+ 末条进行中回答。
///
/// 每个 step 产 2 个过程行：1 条思考行（`assistant/message` 正文为空、只有
/// reasoning，不生成时间线条目）+ 1 条工具行（call/result 按 callId 合并）。
/// 组抬头文案因此是「1 次工具调用」，与截图一致。
List<Map<String, dynamic>> _runningTurnHistory({
  int steps = _fixtureSteps,
  int extraSteps = 0,
}) {
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
    'text': '帮我排查子代理会话滚动问题',
    'sourceKind': 'user',
  });
  for (var i = 0; i < steps + extraSteps; i++) {
    // 注意：同一 (turn, step) 的多条 reasoning 消息在 `TurnProcessTracker.build()`
    // 只保留 seq 最大的一条（turn_process.dart 的 reasoningByStep 去重），
    // 所以每个 step 固定只造 1 条思考行——多造不会增加过程行。
    add('assistant/message', {
      'turn': 1,
      'step': 1 + i,
      'messageId': 'r$i',
      'text': '',
      'reasoning': '第 $i 步：先确认滚动跟随的当前状态',
      'reasoningChars': 18,
    });
    add('tool/call', {
      'turn': 1,
      'step': 1 + i,
      'callId': 'c$i',
      'name': 'shell',
      'arguments': 'grep -n scroll lib/screens/chat_screen.dart | sed -n ${i}p',
    });
    add('tool/result', {
      'turn': 1,
      'step': 1 + i,
      'callId': 'c$i',
      'name': 'shell',
      'text': '第 $i 处命中的滚动代码行',
    });
  }
  add('assistant/message', {
    'turn': 1,
    'step': 1 + steps + extraSteps,
    'messageId': 'a-last',
    'text': '继续检查中……',
  });
  return events;
}

class _LiveTail {
  const _LiveTail({
    required this.index,
    required this.top,
    required this.bottom,
    required this.height,
    required this.isProjectionEnd,
  });

  final int index;
  final double top;
  final double bottom;
  final double height;
  final bool isProjectionEnd;
}

/// 「显示更多」行的实测几何：文案 Text 与其最近的 InkWell（48dp 命中区）。
class _ShowMoreInfo {
  const _ShowMoreInfo({
    required this.text,
    required this.textRect,
    required this.rowRect,
    required this.inViewport,
  });

  final String text;
  final Rect textRect;
  final Rect? rowRect;
  final bool inViewport;

  double? get rowHeight => rowRect?.height;
  double? get textHeight => textRect.height;
}

/// 从生产 ChatScreen 与真实 RenderObject 读出的测量层（与 #114/#118 同款口径）。
class _Probe {
  _Probe(this.tester)
      : _state = tester.state(find.byType(ChatScreen)),
        viewport = tester.renderObject<RenderBox>(find.byType(CustomScrollView));

  final WidgetTester tester;
  final dynamic _state;
  final RenderBox viewport;

  bool get intentFollow => _state.debugPinnedToBottom as bool;
  bool get showJumpToLatest => _state.debugShowJumpToLatest as bool;
  bool get followBottomScheduled => _state.debugFollowBottomScheduled as bool;
  double get liveBottomGap => _state.debugLiveBottomGap as double;
  int get followJumps => _state.debugFollowJumps as int;
  double? get lastFollowTarget => _state.debugLastFollowTarget as double?;
  int get scrollToBottomCallbacks =>
      _state.debugScrollToBottomCallbacks as int;

  ScrollPosition get position => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable, skipOffstage: false),
            )
            .first,
      )
      .position;

  Rect get viewportRect => tester.getRect(find.byType(CustomScrollView));

  double get designBottom => viewportRect.bottom - _designBottomInset;

  double get pixels => position.pixels;
  double get maxExtent => position.maxScrollExtent;
  double get minExtent => position.minScrollExtent;
  double get viewportDimension => position.viewportDimension;
  double get distanceToEnd => position.maxScrollExtent - position.pixels;

  /// 「maxScrollExtent 声明的末端」与「真实已构建内容末端」的差（正 = 幽灵高度）。
  double? get ghostExtent {
    final end = tail;
    if (end == null) return null;
    final declaredContentEnd = pixels + (end.bottom - viewportRect.top);
    return (maxExtent + viewportDimension) - declaredContentEnd;
  }

  double get rangeError {
    final belowMin = position.minScrollExtent - position.pixels;
    final aboveMax = position.pixels - position.maxScrollExtent;
    if (belowMin > 0) return belowMin;
    if (aboveMax > 0) return aboveMax;
    return 0;
  }

  bool get frameScheduled => tester.binding.hasScheduledFrame;

  /// 回底按钮可见性：`_JumpToLatestButton` 用 AnimatedOpacity 表达（visible→1）。
  bool get jumpButtonVisible {
    for (final element in find
        .byType(AnimatedOpacity, skipOffstage: false)
        .evaluate()
        .toList()) {
      final widget = element.widget as AnimatedOpacity;
      final icon = find.descendant(
        of: find.byWidget(widget, skipOffstage: false),
        matching: find.byIcon(Icons.keyboard_arrow_down, skipOffstage: false),
        matchRoot: false,
      );
      if (icon.evaluate().isNotEmpty) return widget.opacity > 0.5;
    }
    return false;
  }

  RenderSliverMultiBoxAdaptor? get _liveSliver {
    for (final element in find
        .byType(SliverList, skipOffstage: false)
        .evaluate()
        .toList()
        .reversed) {
      final render = element.renderObject;
      if (render is RenderSliverMultiBoxAdaptor) return render;
    }
    return null;
  }

  RenderSliver? get liveSliverGeometry => _liveSliver;

  SliverChildBuilderDelegate? get _liveDelegate {
    for (final element in find
        .byType(SliverList, skipOffstage: false)
        .evaluate()
        .toList()
        .reversed) {
      final delegate = (element.widget as SliverList).delegate;
      if (delegate is SliverChildBuilderDelegate) return delegate;
    }
    return null;
  }

  int get projectionEndIndex {
    final count = _liveDelegate?.childCount;
    return count == null ? -1 : count - 1;
  }

  List<RenderBox> get builtChildren {
    final sliver = _liveSliver;
    final out = <RenderBox>[];
    if (sliver == null) return out;
    RenderBox? child = sliver.firstChild;
    while (child != null) {
      out.add(child);
      child = sliver.childAfter(child);
    }
    return out;
  }

  int _indexOf(RenderBox child) {
    final parentData = child.parentData;
    if (parentData is SliverMultiBoxAdaptorParentData) {
      return parentData.index ?? -1;
    }
    return -1;
  }

  _LiveTail? get tail {
    final children = builtChildren;
    if (children.isEmpty) return null;
    final last = children.last;
    final origin = last.localToGlobal(Offset.zero);
    final index = _indexOf(last);
    return _LiveTail(
      index: index,
      top: origin.dy,
      bottom: origin.dy + last.size.height,
      height: last.size.height,
      isProjectionEnd: index == projectionEndIndex,
    );
  }

  /// 末端到设计底部留白线的残差（正 = 下方还有空白；负 = 越过底边）。
  double? get tailResidual {
    final end = tail;
    if (end == null) return null;
    return designBottom - end.bottom;
  }

  /// 最后一个「有高度」的已构建子项到设计底边的残差（排除零高度隐藏项干扰）。
  double? get lastNonZeroResidual {
    final children = builtChildren;
    for (final child in children.reversed) {
      if (child.size.height <= 0.5) continue;
      final origin = child.localToGlobal(Offset.zero);
      return designBottom - (origin.dy + child.size.height);
    }
    return null;
  }

  /// 「显示更多（还有 N 行）」行是否已构建、其文案/Text/命中区高度与是否在视口内。
  _ShowMoreInfo? get showMore {
    final finder = find.textContaining('显示更多', skipOffstage: false);
    final elements = finder.evaluate().toList();
    if (elements.isEmpty) return null;
    final element = elements.first;
    final textRect = tester.getRect(
      find.byElementPredicate((e) => e == element, skipOffstage: false),
    );
    Rect? rowRect;
    final inkWell = find.ancestor(
      of: find.byElementPredicate((e) => e == element, skipOffstage: false),
      matching: find.byType(InkWell, skipOffstage: false),
    );
    final inkElements = inkWell.evaluate().toList();
    if (inkElements.isNotEmpty) {
      final first = inkElements.first;
      final box = first.renderObject;
      if (box is RenderBox && box.hasSize) {
        rowRect = box.localToGlobal(Offset.zero) & box.size;
      }
    }
    final text = (element.widget is Text)
        ? (element.widget as Text).data
        : '${element.widget}';
    return _ShowMoreInfo(
      text: text ?? '',
      textRect: textRect,
      rowRect: rowRect,
      inViewport: textRect.overlaps(viewportRect),
    );
  }

  /// 已构建的组抬头个数（运行/完成两种文案都算）。
  int get groupHeaderCount =>
      find.textContaining('次工具调用', skipOffstage: false).evaluate().length +
      find.textContaining('正在调用工具', skipOffstage: false).evaluate().length;

  /// 最近到的校正目标是否等于当前 max（用于区分「算错」与「没触发」）。
  double? get lastTarget => lastFollowTarget;
}

class _Replay {
  _Replay(this.tester, this.store, this.probe, this.label);

  final WidgetTester tester;
  final AppStore store;
  final _Probe probe;
  final String label;
  final List<String> rows = [];
  int _seq = 1000;

  double? minTail;
  double? maxTail;
  bool sawPositiveTail = false;
  bool sawButton = false;
  bool sawReading = false;

  int get frame => rows.length;

  Future<void> pumpFrame({
    String? tag,
    Duration delta = const Duration(milliseconds: 16),
  }) async {
    await tester.pump(delta);
    record(tag);
  }

  void record([String? tag]) {
    final end = probe.tail;
    final tail = probe.tailResidual;
    if (tail != null) {
      minTail = minTail == null || tail < minTail! ? tail : minTail;
      maxTail = maxTail == null || tail > maxTail! ? tail : maxTail;
      if (tail > 0.5) sawPositiveTail = true;
    }
    final btn = probe.jumpButtonVisible;
    if (btn) sawButton = true;
    if (!probe.intentFollow) sawReading = true;
    final more = probe.showMore;
    final sliver = probe.liveSliverGeometry;
    rows.add(
      '#${rows.length}${tag == null ? '' : '($tag)'} '
      'intent=${probe.intentFollow ? 'follow' : 'reading'} '
      'px=${probe.pixels.toStringAsFixed(0)} '
      'min=${probe.minExtent.toStringAsFixed(0)} '
      'max=${probe.maxExtent.toStringAsFixed(0)} '
      'v=${probe.viewportDimension.toStringAsFixed(0)} '
      'dist=${probe.distanceToEnd.toStringAsFixed(1)} '
      'tail=${tail?.toStringAsFixed(1) ?? 'none'} '
      'ghost=${probe.ghostExtent?.toStringAsFixed(1) ?? 'none'} '
      'tailIdx=${end?.index ?? -1}/${probe.projectionEndIndex} '
      'built=${probe.builtChildren.length} '
      'tailH=${end?.height.toStringAsFixed(0) ?? 'none'} '
      'lastNonZero=${probe.lastNonZeroResidual?.toStringAsFixed(1) ?? 'none'} '
      'more=${more == null ? 'none' : '"${more.text}" h=${more.rowHeight?.toStringAsFixed(0) ?? '?'} '
          'textH=${more.textHeight?.toStringAsFixed(0) ?? '?'} inVp=${more.inViewport}'} '
      'groups=${probe.groupHeaderCount} '
      'sliverExtent=${sliver?.geometry?.scrollExtent.toStringAsFixed(0) ?? 'none'} '
      'gap=${probe.liveBottomGap.toStringAsFixed(1)} '
      'range=${probe.rangeError.toStringAsFixed(1)} '
      'queued=${probe.followBottomScheduled} '
      'jumps=${probe.followJumps} '
      'target=${probe.lastTarget?.toStringAsFixed(0) ?? 'none'} '
      'stb=${probe.scrollToBottomCallbacks} '
      'showJump=${probe.showJumpToLatest} '
      'btn=$btn '
      'frameScheduled=${probe.frameScheduled}',
    );
  }

  void recordRaw(String line) => rows.add('#${rows.length} $line');

  String recent({int count = 16}) {
    final start = rows.length > count ? rows.length - count : 0;
    return '\n${rows.sublist(start).join('\n')}';
  }

  String summary() =>
      '[$label] frames=${rows.length} minTail=${minTail?.toStringAsFixed(1)} '
      'maxTail=${maxTail?.toStringAsFixed(1)} positiveTail=$sawPositiveTail '
      'button=$sawButton reading=$sawReading';

  /// 注入一条运行中会话事件（同一次挂载内，不重挂）；seq 单调递增。
  void inject(String type, Map<String, dynamic> data) {
    store.injectFrame({
      'type': 'session/event',
      'sessionId': _session,
      'event': {
        'seq': _seq++,
        'type': type,
        'data': data,
        'time': _seq * 10,
      },
    });
  }

  /// 注入后台任务快照帧（真实 SSE session/jobs 帧形状）。
  void injectJobs(List<Map<String, dynamic>> jobs) {
    store.injectFrame({
      'type': 'session/jobs',
      'sessionId': _session,
      'jobs': jobs,
    });
  }

  /// 逐帧推进并断言「跟随态下真实末端贴合设计底边 + 无回底按钮」。
  ///
  /// 变红 = 复现了截图现象（正 tailResidual 且/或回底按钮可见）；失败消息带最近帧。
  Future<void> expectPinned({
    required String step,
    int frames = 8,
    double tolerance = 2,
  }) async {
    for (var i = 0; i < frames; i++) {
      await pumpFrame(tag: '$step+$i');
    }
    final tail = probe.tailResidual;
    expect(
      tail,
      isNotNull,
      reason: '$label $step：取不到投影末端几何（按未到达处理）${recent()}',
    );
    expect(
      tail!.abs(),
      lessThanOrEqualTo(tolerance),
      reason: '$label $step：投影末端未贴合设计底边（tailResidual=$tail，'
          '正=内容下方空白）${recent()}',
    );
    expect(
      probe.distanceToEnd.abs(),
      lessThanOrEqualTo(1),
      reason: '$label $step：滚动位置未在真实末端（dist=${probe.distanceToEnd}）${recent()}',
    );
    expect(
      probe.jumpButtonVisible,
      isFalse,
      reason: '$label $step：跟随态不应出现回底按钮${recent()}',
    );
  }
}

Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  required WorkStepDisplayMode mode,
  bool timelineDebug = false,
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
  bool settle = true,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode
    ..timelineDebug = timelineDebug;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() async {
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: ChatScreen(
            key: ValueKey<String>('issue118-detailed-${mode.name}-$timelineDebug'),
            store: store,
            apiClient: backend.api,
            onTitleChanged: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  if (settle) await tester.pumpAndSettle();
  return store;
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  // ── 基线：详细档 + 104 行 + 运行中 ─────────────────────────────────────────
  //
  // 先验证夹具前提（详细档组抬头可见、单轮 >50 行触发「显示更多（还有 54 行）」、
  // 运行中无 turn/end），再验证 mount 后是否已贴在真实末端。
  testWidgets('基线：详细档 + 104 过程行 + 运行中，mount 后应钉在真实末端',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '基线');
      replay.record('mount');
      // 夹具前提：分批入口存在（文案与截图一致：还有 54 行）。
      final more = probe.showMore;
      expect(more, isNotNull, reason: '夹具前提：单轮 >50 行应出现「显示更多」${replay.recent()}');
      expect(more!.text, contains('还有 54 行'),
          reason: '夹具前提：104 行分批后应剩 54 行${replay.recent()}');
      // 详细档组抬头展开：组抬头应已构建（视口内可数个）。
      expect(probe.groupHeaderCount, greaterThan(0),
          reason: '夹具前提：运行中详细档应渲染组抬头${replay.recent()}');
      // 松手后仍在跟随态且到真实末端。
      await replay.expectPinned(step: 'mount', frames: 8);
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试 A：todo/write 插入（截图里的「任务清单已更新」来源）──
  testWidgets('尝试A：详细档 + 104 行 + 运行中，插入 todo/write ×3', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'todo/write×3');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      for (var round = 0; round < 3; round++) {
        replay.inject('todo/write', {
          'turn': 1,
          'todos': [
            for (var i = 0; i < 4; i++)
              {
                'id': 't$i',
                'content': '#${118 + i} 复现任务 $round-$i',
                'status': i == 0 ? 'in_progress' : 'pending',
              },
          ],
        });
        await replay.expectPinned(step: 'todo$round', frames: 8);
      }
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试 B：session/jobs（顶部 JobCard 显隐改变视口高度）──
  testWidgets('尝试B：详细档 + 104 行 + 运行中，插入 session/jobs', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'session/jobs');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      replay.injectJobs([
        {'id': 'job-1', 'label': '后台任务 A', 'status': 'running'},
      ]);
      await replay.expectPinned(step: 'jobs1', frames: 8);
      // 多个后台任务（JobCard 更高，视口更矮）：
      replay.injectJobs([
        {'id': 'job-1', 'label': '后台任务 A', 'status': 'running'},
        {'id': 'job-2', 'label': '后台任务 B', 'status': 'running'},
        {'id': 'job-3', 'label': '后台任务 C', 'status': 'running'},
      ]);
      await replay.expectPinned(step: 'jobs3', frames: 8);
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试 C：越过分批边界的新过程行（隐藏行递增，「显示更多」文案变化）──
  testWidgets('尝试C：详细档 + 104 行 + 运行中，越过分批边界继续产过程行',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '分批边界');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      // 新 step 的思考+工具行全部落在 50 行分批窗口之外：渲染高度应不变，
      // 但「显示更多」计数增长（54 → 56 → …），可暴露计数/布局不同步。
      for (var i = 0; i < 6; i++) {
        replay.inject('assistant/message', {
          'turn': 1,
          'step': _fixtureSteps + 1 + i,
          'messageId': 'late-r$i',
          'text': '',
          'reasoning': '越界步骤 $i 的思考',
          'reasoningChars': 9,
        });
        replay.inject('tool/call', {
          'turn': 1,
          'step': _fixtureSteps + 1 + i,
          'callId': 'late-c$i',
          'name': 'shell',
          'arguments': 'echo late $i',
        });
        replay.inject('tool/result', {
          'turn': 1,
          'step': _fixtureSteps + 1 + i,
          'callId': 'late-c$i',
          'name': 'shell',
          'text': 'late ok $i',
        });
        await replay.expectPinned(step: 'late$i', frames: 4);
      }
      final more = probe.showMore;
      expect(more, isNotNull, reason: '夹具前提：分批入口仍在${replay.recent()}');
      expect(more!.text, contains('还有 66 行'),
          reason: '夹具前提：6 个 step 新增 12 行后应剩 66 行（实际 ${more.text}）'
              '${replay.recent()}');
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试 D：与截图完全同形——截图里任务面板是展开态（视口变矮）──
  //
  // 这是真实用户动作（点任务面板抬头展开清单），但截图里它确实处于展开态，
  // 且任务面板在 composer 上方、只改变消息视口高度，不经过滚动层。
  testWidgets('尝试D：详细档 + 104 行 + 运行中，展开任务面板使视口变矮',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '任务面板展开');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      // 先让任务面板出现，再点开（截图里是展开态：1 进行中 · 4 待处理 + 5 行清单）。
      replay.inject('todo/write', {
        'turn': 1,
        'todos': [
          for (var i = 0; i < 5; i++)
            {
              'id': 't$i',
              'content': '任务清单项 $i：验证滚动跟随与分批边界',
              'status': i == 0 ? 'in_progress' : 'pending',
            },
        ],
      });
      await replay.expectPinned(step: 'todos', frames: 8);
      final summaryFinder = find.textContaining('待处理');
      expect(summaryFinder.evaluate().isNotEmpty, isTrue,
          reason: '夹具前提：任务面板折叠态计数应可见${replay.recent()}');
      await tester.tap(summaryFinder.first);
      for (var i = 0; i < 8; i++) {
        await replay.pumpFrame(tag: 'todoExpanded+$i');
      }
      // 记录（方向相反，**不是** #118 的正向空白）：展开任务面板让消息视口变矮 90px，
      // 但面板 toggle 既不请求跟随、也不重测底部占位 → 内容被裁到视口下方
      // （tailResidual=-90），8 帧后仍不恢复。若将来修复为「视口高度变化后跟随」，
      // 本断言应改为 |tail|<=2 并删除这段记录注释。
      expect(probe.tailResidual!, lessThan(-30),
          reason: '记录用：预期展开面板后内容被裁在视口下方${replay.recent()}');
      expect(probe.jumpButtonVisible, isFalse,
          reason: '该状态下回底按钮仍隐藏（dist=90≤160 且跟随态）${replay.recent()}');
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 对照 1：标准档（截图里的组抬头是折叠态箭头的可能口径）──
  testWidgets('对照1：标准档 + 104 行 + 运行中，插入 todo/write ×2', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.standard,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '标准档');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      for (var round = 0; round < 2; round++) {
        replay.inject('todo/write', {
          'turn': 1,
          'todos': [
            for (var i = 0; i < 4; i++)
              {
                'id': 't$i',
                'content': '标准档任务 $round-$i',
                'status': 'pending',
              },
          ],
        });
        await replay.expectPinned(step: 'todo$round', frames: 8);
        replay.injectJobs([
          {'id': 'job-1', 'label': '后台任务 A', 'status': 'running'},
        ]);
        await replay.expectPinned(step: 'jobs$round', frames: 8);
      }
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 对照 2：调试模式（alpha.21 截图的「任务清单已更新」时间线卡在 rc.2 只剩调试可见）──
  testWidgets('对照2：详细档 + 104 行 + 运行中 + 调试模式，todo/write 插入时间线卡',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
        timelineDebug: true,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '调试模式');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      for (var round = 0; round < 3; round++) {
        replay.inject('todo/write', {
          'turn': 1,
          'todos': [
            for (var i = 0; i < 4; i++)
              {
                'id': 't$i',
                'content': '调试任务 $round-$i',
                'status': i == 0 ? 'in_progress' : 'pending',
              },
          ],
        });
        await replay.expectPinned(step: 'todo$round', frames: 8);
      }
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试H：详细档运行中 → turn/end → 新一轮开始（过程组由展开变折叠，内容大幅变矮）──
  //
  // 真实运行中会话最常见的布局突变：本轮的 25 个展开组（约 3000dp）在 turn/end 后
  // 全部折叠成组抬头（约 1200dp），随后新一轮 turn/start + 新过程行。
  testWidgets('尝试H：详细档 104 行运行中 → turn/end → 新轮开始', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'turn/end→新轮');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      replay.inject('turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      });
      await replay.expectPinned(step: 'turnEnd', frames: 8);
      // 新一轮：turn/start + 提问 + 新工具 + 新回答。
      replay.inject('turn/start', {'turn': 2});
      replay.inject('user/message', {
        'messageId': 'u2',
        'text': '继续',
        'sourceKind': 'user',
      });
      replay.inject('tool/call', {
        'turn': 2,
        'step': 1,
        'callId': 'n1',
        'name': 'shell',
        'arguments': 'echo next',
      });
      replay.inject('tool/result', {
        'turn': 2,
        'step': 1,
        'callId': 'n1',
        'name': 'shell',
        'text': 'next ok',
      });
      replay.inject('assistant/message', {
        'turn': 2,
        'step': 2,
        'messageId': 'a2',
        'text': '继续检查中……',
      });
      await replay.expectPinned(step: 'turn2', frames: 8);
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试I：SSE 突发（同一帧内连续多帧）──
  testWidgets('尝试I：详细档 104 行运行中，同一帧内注入 6 条布局变化事件', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'SSE 突发');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      for (var round = 0; round < 3; round++) {
        replay.inject('todo/write', {
          'turn': 1,
          'todos': [
            {
              'id': 't$round',
              'content': '突发任务 $round',
              'status': 'in_progress',
            },
          ],
        });
        replay.injectJobs([
          {'id': 'job-$round', 'label': '任务 $round', 'status': 'running'},
        ]);
        await replay.expectPinned(step: 'burst$round', frames: 4);
      }
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试J：详细档 + 1.5x 大字号（截图真机字号未知，验收曾提 1.5x）──
  testWidgets('尝试J：详细档 + 104 行 + 1.5x 字号 + todo/write + jobs', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.detailed,
        textScaler: const TextScaler.linear(1.5),
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '详细档1.5x');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      replay.inject('todo/write', {
        'turn': 1,
        'todos': [
          for (var i = 0; i < 4; i++)
            {
              'id': 't$i',
              'content': '大字号任务 $i',
              'status': 'pending',
            },
        ],
      });
      await replay.expectPinned(step: 'todo', frames: 8);
      replay.injectJobs([
        {'id': 'job-1', 'label': '后台任务 A', 'status': 'running'},
      ]);
      await replay.expectPinned(step: 'jobs', frames: 8);
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试K：多轮长会话（截图里的 3 个「1 次工具调用」抬头更像 3 个已完成轮次）──
  testWidgets('尝试K：详细档，3 个已完成轮次 + 运行中 104 行轮次，插入 todo/write + jobs',
      (tester) async {
    try {
      final history = <Map<String, dynamic>>[];
      var seq = 1;
      void add(String type, Map<String, dynamic> data) => history.add({
            'seq': seq++,
            'type': type,
            'data': data,
            'time': 1000 + seq * 10,
          });
      // 3 个已完成轮次，每轮 1 次工具调用（详细档：已完成组的抬头折叠成 3 行）。
      for (var turn = 1; turn <= 3; turn++) {
        add('turn/start', {'turn': turn});
        add('user/message', {
          'messageId': 'u$turn',
          'text': '第 $turn 轮提问',
          'sourceKind': 'user',
        });
        add('tool/call', {
          'turn': turn,
          'step': 1,
          'callId': 't$turn',
          'name': 'shell',
          'arguments': 'echo $turn',
        });
        add('tool/result', {
          'turn': turn,
          'step': 1,
          'callId': 't$turn',
          'name': 'shell',
          'text': 'ok $turn',
        });
        add('assistant/message', {
          'turn': turn,
          'step': 1,
          'messageId': 'a$turn',
          'text': '第 $turn 轮回答',
        });
        add('turn/end', {
          'turn': turn,
          'reason': {'kind': 'completed'},
        });
      }
      // 运行中的第 4 轮：104 个过程行。
      final running = _runningTurnHistory();
      for (final e in running) {
        history.add({...e, 'seq': (e['seq'] as int) + seq - 1});
      }
      final store = await _mount(
        tester,
        _Backend(history),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '多轮+运行中104行');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      replay.inject('todo/write', {
        'turn': 4,
        'todos': [
          for (var i = 0; i < 4; i++)
            {
              'id': 't$i',
              'content': '多轮任务 $i',
              'status': 'pending',
            },
        ],
      });
      await replay.expectPinned(step: 'todo', frames: 8);
      replay.injectJobs([
        {'id': 'job-1', 'label': '后台任务 A', 'status': 'running'},
      ]);
      await replay.expectPinned(step: 'jobs', frames: 8);
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试L：标准档运行中 → 用户先上翻（阅读态）→ turn/end（过程段自动折叠、内容变矮）──
  //
  // 这是「截图里内容矮于视口 + 回底按钮可见」唯一自洽的状态组合：阅读态下内容因
  // 折叠/分批变矮 → 位置被夹到新 max、内容顶对齐、回底按钮（阅读态恒显示）。
  testWidgets('尝试L：标准档 104 行运行中 → 上翻进阅读态 → turn/end 自动折叠', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory()),
        mode: WorkStepDisplayMode.standard,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '阅读态+turn/end');
      replay.record('mount');
      await replay.expectPinned(step: 'mount', frames: 8);
      // 用户上翻阅读（拖 300 向上 = 内容下移 300）。
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pump(const Duration(milliseconds: 300));
      replay.record('dragUp');
      // ignore: avoid_print
      print('[118] dragUp:${replay.recent(count: 2)}');
      // 本轮结束：标准档自动折叠整个过程段（高度大幅变矮）。
      replay.inject('turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      });
      for (var i = 0; i < 10; i++) {
        await replay.pumpFrame(tag: 'end+$i');
      }
      // ignore: avoid_print
      print('[118] afterEnd:${replay.recent(count: 3)}');
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
      // 阅读态 + 短内容 + 底部占位缺失 → 正 tailResidual + 回底按钮。
      final tail = probe.tailResidual;
      // ignore: avoid_print
      print('[118] FINAL tail=$tail btn=${probe.jumpButtonVisible} '
          'showJump=${probe.showJumpToLatest} gap=${probe.liveBottomGap} '
          'dist=${probe.distanceToEnd} max=${probe.maxExtent} '
          'reading=${!probe.intentFollow}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 尝试M：`paged` 状态下短内容 —— 代码里 #77 的底部占位对 paged 永久停用 ──
  //
  // `_scheduleLiveBottomGapMeasure` 的 `shortEnough` 条件是 `!paged && actualMax<=1`；
  // `paged = _olderItems.isNotEmpty`（用户上翻加载过更早历史后为真）。因此「运行中
  // 长轮次 + 用户上翻过 + 本轮结束自动折叠 → 内容矮于视口」时，内容会**顶对齐**、
  // 下方留大段空白，阅读态下回底按钮常显——与截图形态一致。这里用真实分页窗口回放。
  testWidgets('尝试M：上翻分页（paged）后本轮结束自动折叠 → 短内容空白是否持续',
      (tester) async {
    try {
      // 3 个已完成轮次（每轮 1 次工具）+ 第 4 轮运行中 104 行过程。
      final history = <Map<String, dynamic>>[];
      var seq = 1;
      void add(String type, Map<String, dynamic> data) => history.add({
            'seq': seq++,
            'type': type,
            'data': data,
            'time': 1000 + seq * 10,
          });
      for (var turn = 1; turn <= 3; turn++) {
        add('turn/start', {'turn': turn});
        add('user/message', {
          'messageId': 'u$turn',
          'text': '第 $turn 轮提问',
          'sourceKind': 'user',
        });
        add('tool/call', {
          'turn': turn,
          'step': 1,
          'callId': 't$turn',
          'name': 'shell',
          'arguments': 'echo $turn',
        });
        add('tool/result', {
          'turn': turn,
          'step': 1,
          'callId': 't$turn',
          'name': 'shell',
          'text': 'ok $turn',
        });
        add('assistant/message', {
          'turn': turn,
          'step': 1,
          'messageId': 'a$turn',
          'text': '第 $turn 轮回答',
        });
        add('turn/end', {
          'turn': turn,
          'reason': {'kind': 'completed'},
        });
      }
      final running = _runningTurnHistory();
      for (final e in running) {
        history.add({...e, 'seq': (e['seq'] as int) + seq - 1});
      }
      // 初始窗口只给最后 50 条（真实服务端窗口）；更早由 before 分页取回。
      final store = await _mount(
        tester,
        _Backend(history, initialLimit: 50),
        mode: WorkStepDisplayMode.standard,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'paged+折叠');
      replay.record('mount');
      // ignore: avoid_print
      print('[118] mount:${replay.recent(count: 2)}');
      // 用户上翻（触发无限模式分页 → paged=true）。
      for (var i = 0; i < 2; i++) {
        await tester.drag(
            find.byType(CustomScrollView), const Offset(0, 520));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
      }
      replay.record('dragUp');
      // ignore: avoid_print
      print('[118] dragUp:${replay.recent(count: 2)}');
      // 本轮结束：标准档自动折叠过程段 → 内容大幅变矮。
      replay.inject('turn/end', {
        'turn': 4,
        'reason': {'kind': 'completed'},
      });
      for (var i = 0; i < 10; i++) {
        await replay.pumpFrame(tag: 'end+$i');
      }
      // ignore: avoid_print
      print('[118] afterEnd:${replay.recent(count: 4)}');
      // 折叠后内容已矮于视口（max≈0），不存在「停在离底 40px」这种位置；
      // 直接验证核心验收点：pixels 不得越界为负、内容不得被推到视口上方。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 100));
      replay.record('afterFold');
      // ignore: avoid_print
      print('[118] afterPark:${replay.recent(count: 3)}');
      // 持续多帧确认不是瞬态：仍保持「内容下方大段空白 + 回底按钮可见」。
      for (var i = 0; i < 6; i++) {
        await replay.pumpFrame(tag: 'park+$i');
      }
      final tail = probe.tailResidual;
      // ignore: avoid_print
      print('[118] FINAL tail=$tail btn=${probe.jumpButtonVisible} '
          'showJump=${probe.showJumpToLatest} gap=${probe.liveBottomGap} '
          'dist=${probe.distanceToEnd} max=${probe.maxExtent} '
          'reading=${!probe.intentFollow}');
      // 验收判定（issue #118 修复后）：内容因折叠变短后不得留下大段空白。
      //
      // 修复前实测（保留在本文件顶部注释）：tail=+526、px=-40、max=0、按钮可见。
      // 修复方式不是启用 paged 底部占位（会重现 issue #76 的拉扯），而是把越界的
      // pixels 拉回 [0, max]：`_clampOverscrollAfterShrink`。
      // 判据不是 tailResidual（内容少于一屏时它天然为正——那是「内容之后的空间」，
      // 不是异常空白），而是 **pixels 是否越界**：

      // 修复前实测 px=-40：内容顶被推到视口上方 40px，用户看到内容中段、下方大段空白。
      // 修复后 px=0：内容顶对齐视口顶，剩余空间在内容之后，属正常短内容布局。
      expect(probe.maxExtent, lessThan(1),
          reason: '前提：折叠后内容确实不可滚动（max≈0）${replay.recent()}');
      expect(probe.pixels, greaterThanOrEqualTo(-0.5),
          reason: '修复后像素不得越界为负（内容顶不该被推到视口上方）'
              '${replay.recent()}');
      expect(tail, isNotNull, reason: '应能取到投影末端${replay.recent()}');
      // 回底按钮仍可见是 issue #114 定的产品行为（阅读态恒显入口），不是缺陷；
      // 但它必须真的能回到「内容底部」，而不是跳进空白区。
      // 不再断言意图固定为 reading：折叠后内容不可滚动，意图由用户最后一次
      // 真实手势位置决定；本用例只锁定「越界空白」这一个缺陷不再出现。
      // ignore: avoid_print
      print('[118] ${replay.summary()}');
    } finally {
      await _finish(tester);
    }
  });
}
