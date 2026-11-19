// issue #114 阶段 A：真实动态回放，测量「跟随意图 / 真实投影末端 / 阅读锚点 / 范围」。
//
// 本文件不复制生产滚动算法：
// - intent 取生产 ChatScreen 的只读诊断（chat_screen.dart 的 debugPinnedToBottom 等）。
// - tailResidual 取真实 live SliverList 的**最后投影子项** RenderObject，与 viewport 同一
//   坐标系，扣掉设计底部内边距（6px）；不搜全屏 Text（活动条/输入框文字会被误当末端）。
// - anchorResidual 用真实子项 index + 相对视口偏移（内容身份 + 局部偏移），不用 pixels 冒充。
// - 一次 pumpWidget 挂载，后续全部通过 store.injectFrame 注入；不卸载重挂。
// - textScaler 显式设置并在用例内断言真实生效。
// - 不使用 tester.ensureVisible / jumpTo / 先点回底来掩盖失败。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue114_scroll_follow_replay_test.dart

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

/// live 列表 SliverPadding 的底部内边距（chat_screen.dart `_buildLiveView`）。
/// 设计上的「内容底边」在 viewport 底部之上这么多；末端残差以此为基准。
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
          'events': history.length > limit
              ? history.sublist(history.length - limit)
              : history,
          'hasMore': history.length > limit,
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

/// 一次运行中轮次的历史快照（无 turn/end）：用户提问 + 思考 + [tools] 个
/// 工具 call/result（每个 step 一个） + 末条进行中的回答。
///
/// 选这个结构是因为它是四档里最普通的长会话：详细/完全展开档下同一轮里既有
/// 过程块内部高度（思考行、工具卡详情），又有顶部的大块过程块，能真实触发
/// lazy SliverList 的 extents 估值修正。
List<Map<String, dynamic>> _runningTurnHistory({int tools = 10}) {
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

class _ReadingAnchor {
  const _ReadingAnchor({required this.index, required this.viewportOffset});
  final int index;
  final double viewportOffset;
}

/// 从生产 ChatScreen 与真实 RenderObject 读出的测量层。
class _Probe {
  _Probe(this.tester)
    : _state = tester.state(find.byType(ChatScreen)),
      viewport = tester.renderObject<RenderBox>(find.byType(CustomScrollView));

  final WidgetTester tester;
  final dynamic _state;
  final RenderBox viewport;

  // —— 生产只读诊断（intent / 调度 / 校正）——
  bool get intentFollow => _state.debugPinnedToBottom as bool;
  bool get userDragActive => _state.debugUserDragActive as bool;
  bool get followBottomScheduled => _state.debugFollowBottomScheduled as bool;
  bool get settledFollowScheduled => _state.debugSettledFollowScheduled as bool;
  // ADR 0035：底部占位已删除；保留 0 读数用于轨迹日志。
  double get liveBottomGap => 0.0;
  int get followJumps => _state.debugFollowJumps as int;
  int get scrollToBottomCallbacks => _state.debugScrollToBottomCallbacks as int;

  // —— 真实几何 ——
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

  double get distanceToEnd => position.maxScrollExtent - position.pixels;

  /// 相对合法 [minScrollExtent, maxScrollExtent] 的越界；保留 center 的负 min。
  double get rangeError {
    final belowMin = position.minScrollExtent - position.pixels;
    final aboveMax = position.pixels - position.maxScrollExtent;
    if (belowMin > 0) return belowMin;
    if (aboveMax > 0) return aboveMax;
    return 0;
  }

  bool get frameScheduled => tester.binding.hasScheduledFrame;

  // 注意：Viewport 的 onstage 遍历会跳过 geometry.visible=false 的 sliver
  // （lazy 估值跳跃时 live 列表会整体离屏），测量必须显式 skipOffstage: false。
  RenderSliverMultiBoxAdaptor? get _liveSliver {
    for (final element
        in find
            .byType(SliverList, skipOffstage: false)
            .evaluate()
            .toList()
            .reversed) {
      final render = element.renderObject;
      if (render is RenderSliverMultiBoxAdaptor) return render;
    }
    return null;
  }

  SliverChildBuilderDelegate? get _liveDelegate {
    for (final element
        in find
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

  /// 真实投影里已经构建的子项（按渲染顺序）。
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

  /// 当前投影末端（最后一个真实参与投影的布局子项）。未构建时返回 null：
  /// 按 issue §3.2，末端取不到几何属于「未到达」，不能当作 residual = 0。
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

  /// 取阅读线附近的一个已构建子项作为稳定锚点（issue §3.2：内容身份 + 局部偏移）。
  _ReadingAnchor? anchorNear(double viewportOffset) {
    final top = viewportRect.top;
    for (final child in builtChildren) {
      final origin = child.localToGlobal(Offset.zero);
      final localTop = origin.dy - top;
      if (localTop <= viewportOffset &&
          localTop + child.size.height > viewportOffset) {
        return _ReadingAnchor(index: _indexOf(child), viewportOffset: localTop);
      }
    }
    return null;
  }

  /// 锚点相对视口的位移；锚点已不可见/被回收时返回 null。
  double? anchorResidual(_ReadingAnchor anchor) {
    final top = viewportRect.top;
    for (final child in builtChildren) {
      if (_indexOf(child) != anchor.index) continue;
      final localTop = child.localToGlobal(Offset.zero).dy - top;
      return localTop - anchor.viewportOffset;
    }
    return null;
  }
}

/// 一个用例的录制器：每个 pump 之后记录一行实测；失败时把最近若干帧带进断言消息。
class _Replay {
  _Replay(this.tester, this.store, this.probe, this.label);

  final WidgetTester tester;
  final AppStore store;
  final _Probe probe;
  final String label;
  final List<String> rows = [];
  int _seq = 1000;

  int get frame => rows.length;

  Future<void> pumpFrame({
    String? tag,
    Duration delta = const Duration(milliseconds: 16),
  }) async {
    await tester.pump(delta);
    record(tag);
  }

  void record([String? tag]) {
    final tail = probe.tail;
    rows.add(
      '#${rows.length}${tag == null ? '' : '($tag)'} '
      'intent=${probe.intentFollow ? 'follow' : 'reading'} '
      'drag=${probe.userDragActive} '
      'dist=${probe.distanceToEnd.toStringAsFixed(1)} '
      'tail=${probe.tailResidual?.toStringAsFixed(1) ?? 'none'} '
      'tailIdx=${tail?.index ?? -1}/${probe.projectionEndIndex} '
      'gap=${probe.liveBottomGap.toStringAsFixed(1)} '
      'range=${probe.rangeError.toStringAsFixed(1)} '
      'followQueued=${probe.followBottomScheduled} '
      'settleQueued=${probe.settledFollowScheduled} '
      'jumps=${probe.followJumps} '
      'stbCallbacks=${probe.scrollToBottomCallbacks} '
      'frameScheduled=${probe.frameScheduled}',
    );
  }

  void recordRaw(String line) => rows.add('#${rows.length} $line');

  String recent({int count = 12}) {
    final start = rows.length > count ? rows.length - count : 0;
    return '\n${rows.sublist(start).join('\n')}';
  }

  /// 注入一条运行中事件（同一次挂载内，不重挂）；seq 单调递增。
  void inject(String type, Map<String, dynamic> data) {
    store.injectFrame({
      'type': 'session/event',
      'sessionId': _session,
      'event': {'seq': _seq++, 'type': type, 'data': data, 'time': _seq * 10},
    });
  }

  bool _converged(double tolerance) {
    final end = probe.tail;
    if (end == null || !end.isProjectionEnd) return false;
    if (!probe.intentFollow) return false;
    if (probe.rangeError > 1) return false;
    final residual = probe.tailResidual;
    return residual != null && residual.abs() <= tolerance;
  }

  /// issue §3.2 验收预算：本批布局提交后，最多 6 个 16ms 测试帧收敛到
  /// |tailResidual| <= 2、range 误差 <= 1、intent 仍为跟随。
  /// 先记录首帧，再逐帧推进；超预算仍不收敛即失败。
  Future<void> expectConvergesWithin(
    String step, {
    int maxFrames = 6,
    double tolerance = 2,
  }) async {
    var frames = 0;
    while (frames < maxFrames) {
      await pumpFrame(tag: frames == 0 ? step : '$step+$frames');
      frames++;
      if (_converged(tolerance)) return;
    }
    final residual = probe.tailResidual;
    final end = probe.tail;
    expect(
      probe.intentFollow,
      isTrue,
      reason: '$label $step：跟随意图被非用户路径改写${recent()}',
    );
    expect(
      probe.rangeError,
      lessThanOrEqualTo(1),
      reason: '$label $step：滚动位置越界${recent()}',
    );
    expect(end, isNotNull, reason: '$label $step：取不到投影末端几何，按未到达处理${recent()}');
    expect(
      end!.isProjectionEnd,
      isTrue,
      reason:
          '$label $step：末端子项未构建（index ${end.index} != ${probe.projectionEndIndex}），'
          '说明真实末端在视口外/未布局${recent()}',
    );
    expect(
      residual!.abs(),
      lessThanOrEqualTo(tolerance),
      reason:
          '$label $step：$frames 帧内投影末端未贴合设计底边（residual=$residual）'
          '${recent()}',
    );
  }

  /// 断言本帧仍是阅读态：位置未被拉回底部。
  void expectStillReading(String step, {double minDistanceToEnd = 40}) {
    expect(
      probe.distanceToEnd,
      greaterThanOrEqualTo(minDistanceToEnd),
      reason: '$label $step：用户已在阅读，列表不应被拉回底部${recent()}',
    );
    expect(
      probe.userDragActive,
      isTrue,
      reason: '$label $step：真实拖拽应仍处于活动状态${recent()}',
    );
  }
}

/// 挂载一次 ChatScreen。[settle] = false 时只做初始加载，不等待初始 force 定位的
/// 回弹动画结束（用于测量「打开长会话」的首屏真实末端）。
Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  required WorkStepDisplayMode mode,
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
  bool settle = true,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = mode;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // 注入会起 800ms 的会话列表去抖 Timer；测试结束时先让它跑完，避免
  // "Timer is still pending" 掩盖真正的失败原因。
  addTearDown(() async {
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: ChatScreen(
            key: ValueKey<String>('issue114-${mode.name}-${size.width}'),
            store: store,
            apiClient: backend.api,
            onTitleChanged: () {},
          ),
        ),
      ),
    ),
  );
  // textScaler 必须在用例里真实生效，不能只靠用例名声称覆盖。
  final chatContext = tester.element(find.byType(ChatScreen));
  expect(
    MediaQuery.textScalerOf(chatContext).scale(10),
    textScaler.scale(10),
    reason: 'MediaQuery.textScaler 未真实生效',
  );
  await tester.pump(const Duration(milliseconds: 350));
  if (settle) await tester.pumpAndSettle();
  return store;
}

/// 让注入产生的 800ms 去抖 Timer 结束：无论断言是否失败都清理，
/// 避免 "Timer is still pending" 掩盖真正的失败原因。
Future<void> _finish(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('A1-1 打开长会话：初始 force 定位后真实末端 6 帧内可见（不得停在估值外空白）', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 10)),
        mode: WorkStepDisplayMode.detailed,
        settle: false,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '打开长会话');
      replay.record('mount');
      // 打开会话时没有任何用户手势：跟随意图应保持，且真实投影末端必须可见。
      await replay.expectConvergesWithin('初始 force 定位');
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('A1-2 详细档思考增量（同一条目内部增高）：跟随意图在，但帧后校正丢失', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 10)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '详细档思考增量');
      replay.record('mount');
      await replay.expectConvergesWithin('初始');

      final jumpsBefore = probe.followJumps;
      replay.inject('assistant/live-chunk', {
        'turn': 1,
        'step': 30,
        'reasoning': true,
        'text': '滚动分析：确认末端几何与意图。\n',
      });
      await replay.expectConvergesWithin('思考增量');
      // 若能收敛，顺带断言没有多余跳转。
      expect(probe.followJumps, greaterThan(jumpsBefore));
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('A1-3 拖拽中继续流式：已排队的帧后回底不得把用户拉回底部', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 10)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '拖拽中流式');
      replay.record('mount');
      await replay.expectConvergesWithin('初始');

      // 真实纵向拖动（向下拖 = 查看更早），移动量仍在产品 160px「接近底部」窗口内。
      // 分两步移动：第一步越过 touch slop 让 drag 真正开始
      // （DragStartBehavior.start 会丢弃 slop 之前的那段位移）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(CustomScrollView)),
      );
      await gesture.moveBy(const Offset(0, 24));
      await gesture.moveBy(const Offset(0, 96));
      await tester.pump(const Duration(milliseconds: 16));
      replay.record('drag-start');
      expect(
        probe.userDragActive,
        isTrue,
        reason: '真实手势应被识别为拖拽${replay.recent()}',
      );
      expect(
        probe.distanceToEnd,
        greaterThan(40),
        reason: '拖动后应离开底部（实际 ${probe.distanceToEnd}）${replay.recent()}',
      );
      expect(
        probe.intentFollow,
        isTrue,
        reason: '160px 窗口内产品仍视为钉住——这正是旧校正会执行的窗口${replay.recent()}',
      );
      final readingPixels = probe.position.pixels;
      final readingDistanceToEnd = probe.distanceToEnd;
      final anchor = probe.anchorNear(40);

      // 手指未松开时，会话继续流式（真实用户场景：长回答运行中上翻阅读）。
      replay.inject('tool/call', {
        'turn': 1,
        'step': 41,
        'callId': 'c-during-drag',
        'name': 'shell',
        'arguments': 'echo during-drag',
      });
      await replay.pumpFrame(tag: 'stream-during-drag');
      // 同一个 pump 里 jump 发生在帧后，布局还是跳转前的；再推进一帧取真实位移。
      await replay.pumpFrame(tag: 'stream-during-drag+1');
      if (anchor != null) {
        replay.recordRaw(
          'anchorResidual=${probe.anchorResidual(anchor)?.toStringAsFixed(1) ?? 'lost'} '
          '（阅读锚点相对视口位移）',
        );
      }

      // 期望：用户真实手势优先，排队的回底校正必须在执行时失效。
      replay.expectStillReading(
        '拖拽中收到流式事件',
        minDistanceToEnd: readingDistanceToEnd - 2,
      );
      expect(
        probe.position.pixels,
        greaterThanOrEqualTo(readingPixels - 2),
        reason:
            '用户拖拽位置被旧回底校正改写（pixels $readingPixels → '
            '${probe.position.pixels}）${replay.recent()}',
      );
      if (anchor != null) {
        expect(
          probe.anchorResidual(anchor)?.abs() ?? 1e9,
          lessThanOrEqualTo(2),
          reason: '阅读锚点被旧回底校正移动${replay.recent()}',
        );
      }
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('A1-4 详细档流式正文（80ms 节流）：逐批收敛、意图不丢', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 10)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '详细档正文增量');
      replay.record('mount');
      await replay.expectConvergesWithin('初始');

      for (var i = 0; i < 24; i++) {
        replay.inject('assistant/live-chunk', {
          'turn': 1,
          'step': 30,
          'text': '正文第 $i 段，用于逐字/逐批推高内容。\n',
        });
        await replay.expectConvergesWithin('正文增量 $i');
      }
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('A1-6 1.5x 大字号（textScaler 显式生效）：逐批收敛', (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 8)),
        mode: WorkStepDisplayMode.detailed,
        textScaler: const TextScaler.linear(1.5),
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '1.5x 正文增量');
      replay.record('mount');
      await replay.expectConvergesWithin('初始');

      for (var i = 0; i < 16; i++) {
        replay.inject('assistant/live-chunk', {
          'turn': 1,
          'step': 30,
          'text': '大字号正文第 $i 段，换行会显著改变高度。\n',
        });
        await replay.expectConvergesWithin('1.5x 正文增量 $i');
      }
    } finally {
      await _finish(tester);
    }
  });
}
