// issue #118：子代理运行中会话的滚动跟随缺陷。
//
// 已修复（本文件验收）：`session/jobs` / `question/requested` / `mobile/queue` 等
// 改变消息区布局或视口高度的早退分支，此前直接 return、不请求跟随 → 内容被裁到
// 视口下方且不再自动校正。修复后统一由 `_handleEvent` 的统一出口处理（见
// chat_screen.dart `_onEventLayoutChanged`）。
//
// **未复现**：维护者截图里的「内容下方大段空白 + 实心回底按钮」。本文件保留多项
// 复现尝试作为记录（todo/write、逐帧零高度事件、standard + 40 工具 + 1.5x 等），
// 实测均收敛、未出现正向 tailResidual；需要真机日志再定位。
//
// 本文件不复制生产滚动算法：
// - intent / 调度 / 校正次数取 ChatScreen 的只读诊断（debugPinnedToBottom 等）；
// - tailResidual 取真实 live SliverList 的**最后投影子项** RenderObject，与 viewport
//   同一坐标系，扣掉设计底部内边距（6px）；正 = 内容下方还有空白；
// - tailResidual > 0 且 tail.isProjectionEnd 为真、pixels≈max 时，说明
//   `maxScrollExtent` 比真实内容末端大（懒估值/幽灵高度），即「空白」不是没滚动，
//   而是滚到了不存在的末端。
// - 一次 pumpWidget 挂载，后续全部通过 store.injectFrame 注入；不卸载重挂。
// - 不使用 tester.ensureVisible / jumpTo / 先点回底来掩盖失败。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue118_subagent_follow_blank_test.dart

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

const _session = 'session-118';

/// live 列表 SliverPadding 的底部内边距（chat_screen.dart `_buildLiveView`）。
const double _designBottomInset = 6;

class _Backend {
  _Backend(this.history);

  final List<Map<String, dynamic>> history;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue118.test'
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
      } else {
        // 诊断：返回完整历史，模拟「长会话已经通过 catch-up/上翻加载完」的状态。
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

/// 子代理会话的运行中快照（无 turn/end）：
/// 用户提问 + [tools] 个工具 call/result（每个 step 一个）+ 末条进行中的回答。
///
/// tools 大于 [processBatchSize]（50 行对应的工具数）时，过程块会出现
/// 「显示更多（还有 N 行）」，与 #118 截图一致。
List<Map<String, dynamic>> _runningTurnHistory({
  int tools = 10,
  int trailingHiddenEvents = 0,
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
  if (trailingHiddenEvents > 0) {
    // 子代理会话的真实尾部：大量普通模式不可见的协议事件（team/subagent/job…）。
    // 它们在时间线模型里占位、渲染为 SizedBox.shrink（零高度），用于暴露
    // 懒估值把「零高度尾部」按平均高度估大 → maxScrollExtent 幽灵高度。
    for (var i = 0; i < trailingHiddenEvents; i++) {
      add(i.isEven ? 'team/task' : 'subagent/descriptor', {
        'turn': 1,
        'step': 2 + tools,
        'id': 'hidden-$i',
      });
    }
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

/// 从生产 ChatScreen 与真实 RenderObject 读出的测量层（与 #114 A1 同款口径）。
class _Probe {
  _Probe(this.tester)
      : _state = tester.state(find.byType(ChatScreen)),
        viewport = tester.renderObject<RenderBox>(find.byType(CustomScrollView));

  final WidgetTester tester;
  final dynamic _state;
  final RenderBox viewport;

  bool get intentFollow => _state.debugPinnedToBottom as bool;
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
  double get distanceToEnd => position.maxScrollExtent - position.pixels;

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
}

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
    final end = probe.tail;
    rows.add(
      '#${rows.length}${tag == null ? '' : '($tag)'} '
      'intent=${probe.intentFollow ? 'follow' : 'reading'} '
      'px=${probe.pixels.toStringAsFixed(0)} '
      'max=${probe.maxExtent.toStringAsFixed(0)} '
      'dist=${probe.distanceToEnd.toStringAsFixed(1)} '
      'tail=${probe.tailResidual?.toStringAsFixed(1) ?? 'none'} '
      'tailIdx=${end?.index ?? -1}/${probe.projectionEndIndex} '
      'tailH=${end?.height.toStringAsFixed(0) ?? 'none'} '
      'lastNonZero=${probe.lastNonZeroResidual?.toStringAsFixed(1) ?? 'none'} '
      'gap=${probe.liveBottomGap.toStringAsFixed(1)} '
      'range=${probe.rangeError.toStringAsFixed(1)} '
      'queued=${probe.followBottomScheduled} '
      'jumps=${probe.followJumps} '
      'target=${probe.lastFollowTarget?.toStringAsFixed(0) ?? 'none'} '
      'stb=${probe.scrollToBottomCallbacks} '
      'btn=${probe.jumpButtonVisible} '
      'frameScheduled=${probe.frameScheduled}',
    );
  }

  void recordRaw(String line) => rows.add('#${rows.length} $line');

  String recent({int count = 16}) {
    final start = rows.length > count ? rows.length - count : 0;
    return '\n${rows.sublist(start).join('\n')}';
  }

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
}

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
  addTearDown(() async {
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(size: size, textScaler: textScaler),
          child: ChatScreen(
            key: ValueKey<String>('issue118-${mode.name}-${size.width}'),
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
  // ── 已证实并修复的缺陷（#118 修复项 1）：session/jobs 改变视口高度，滚动层必须跟随 ──
  //
  // 实测：会话在底部时收到 session/jobs 帧（后台任务卡出现在时间线外的顶部），
  // 消息视口高度 -35px、maxScrollExtent +35，pixels 不变 → 真实末端被裁到视口下方
  // 35px，且**没有任何校正排队**（queued=false、jumps 不增），直到下一条事件才修。
  //
  // 修复前实测：max +35、pixels 不变、queued=false、jumps 不增（35px 脱底且不再校正）。
  testWidgets(
      '缺陷1（已修）：session/jobs 插入后应继续钉在真实末端',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 12)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'jobs 插入');
      replay.record('mount');
      // 先确认挂载后确实在真实末端。
      expect(probe.tailResidual!.abs(), lessThanOrEqualTo(2),
          reason: '初始未在真实末端${replay.recent()}');
      expect(probe.intentFollow, isTrue);

      final jumpsBefore = probe.followJumps;
      replay.injectJobs([
        {'id': 'job-1', 'label': '后台任务 A', 'status': 'running'}
      ]);
      // 目标行为：6 帧内有界收敛回真实末端。
      for (var i = 0; i < 6; i++) {
        await replay.pumpFrame(tag: 'jobs+$i');
      }
      expect(
        probe.distanceToEnd.abs(),
        lessThanOrEqualTo(1),
        reason: 'session/jobs 让视口变矮后未跟随到底（实测恒为 35px）${replay.recent()}',
      );
      expect(
        probe.tailResidual!.abs(),
        lessThanOrEqualTo(2),
        reason: '真实末端被裁到视口下方（当前实测 tailResidual=-35）${replay.recent()}',
      );
      expect(probe.followJumps, greaterThan(jumpsBefore),
          reason: '应至少执行一次校正${replay.recent()}');
      expect(probe.jumpButtonVisible, isFalse,
          reason: '跟随态且 35px 内不应出现回底按钮${replay.recent()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 统一出口的其它早退分支（issue #118 修复项 2）──
  testWidgets('缺陷1b（已修）：question/requested 让底部问询卡出现、视口变矮后仍钉底',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 12)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '问询卡插入');
      replay.record('mount');
      expect(probe.tailResidual!.abs(), lessThanOrEqualTo(2),
          reason: '初始未在真实末端${replay.recent()}');

      store.injectFrame({
        'type': 'mobile/frame',
        'frame': {
          'type': 'question/requested',
          'rpcId': 'rpc-118',
          'sessionId': _session,
          'questionId': 'rpc-118',
          'questions': [
            {
              'id': 'q1',
              'header': '确认',
              'question': '继续吗？',
              'options': [
                {'label': '继续'},
                {'label': '停止'},
              ],
            },
          ],
        },
      });
      for (var i = 0; i < 6; i++) {
        await replay.pumpFrame(tag: 'question+$i');
      }
      expect(
        probe.tailResidual!.abs(),
        lessThanOrEqualTo(2),
        reason: '问询卡占据 composer 上方高度后，消息区未重新钉到底部${replay.recent()}',
      );
      expect(probe.distanceToEnd.abs(), lessThanOrEqualTo(1),
          reason: '底部问询卡出现后视口未跟随${replay.recent()}');
      await tester.pump(const Duration(seconds: 1));
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('缺陷1c（已修）：turn/end 自动折叠过程段后仍钉底、无回底按钮',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 12)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'turn/end 自动折叠');
      replay.record('mount');
      expect(probe.tailResidual!.abs(), lessThanOrEqualTo(2),
          reason: '初始未在真实末端${replay.recent()}');

      // 结束当前轮：下一帧过程段按 foldPolicy 自动收起（高度大幅变化）。
      replay.inject('turn/end', {
        'turn': 1,
        'reason': {'kind': 'completed'},
      });
      for (var i = 0; i < 8; i++) {
        await replay.pumpFrame(tag: 'turnEnd+$i');
      }
      expect(
        probe.tailResidual!.abs(),
        lessThanOrEqualTo(2),
        reason: 'turn/end 自动折叠后消息区未重新钉到底部${replay.recent()}',
      );
      expect(probe.distanceToEnd.abs(), lessThanOrEqualTo(1),
          reason: '自动折叠后视口脱底${replay.recent()}');
      expect(probe.jumpButtonVisible, isFalse,
          reason: '跟随态不应因自动折叠出现回底按钮${replay.recent()}');
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('缺陷1d（已修）：mobile/queue 队列 dock 出现、视口变矮后仍钉底',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 12)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '队列 dock 插入');
      replay.record('mount');
      expect(probe.tailResidual!.abs(), lessThanOrEqualTo(2),
          reason: '初始未在真实末端${replay.recent()}');

      store.injectFrame({
        'type': 'mobile/queue',
        'sessionId': _session,
        'rows': [
          {
            'id': 'q1',
            'placement': 'queued',
            'text': '排队消息',
            'status': 'queued',
          },
        ],
      });
      for (var i = 0; i < 6; i++) {
        await replay.pumpFrame(tag: 'queue+$i');
      }
      expect(
        probe.tailResidual!.abs(),
        lessThanOrEqualTo(2),
        reason: '队列 dock 占据 composer 上方高度后，消息区未重新钉到底部${replay.recent()}',
      );
      expect(probe.distanceToEnd.abs(), lessThanOrEqualTo(1),
          reason: '队列 dock 出现后视口未跟随${replay.recent()}');
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('缺陷1e（已修）：显示档位切换导致过程段展开/收起后仍钉底',
      (tester) async {
    try {
      // concise 档：过程组隐藏；切到 expanded 后组全部展开，内容显著变高。
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 12)),
        mode: WorkStepDisplayMode.concise,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, '档位切换');
      replay.record('mount');
      final heightBefore = probe.position.maxScrollExtent;

      store.stepDisplayMode = WorkStepDisplayMode.expanded;
      store.notifyListeners();
      for (var i = 0; i < 6; i++) {
        await replay.pumpFrame(tag: 'mode+$i');
      }
      expect(probe.position.maxScrollExtent, greaterThan(heightBefore + 50),
          reason: '夹具前提：切到 expanded 后内容应显著变高${replay.recent()}');
      expect(
        probe.tailResidual!.abs(),
        lessThanOrEqualTo(2),
        reason: '档位切换导致内容变高后，消息区未重新钉到底部${replay.recent()}',
      );
      expect(probe.distanceToEnd.abs(), lessThanOrEqualTo(1),
          reason: '档位切换后视口未跟随${replay.recent()}');
    } finally {
      await _finish(tester);
    }
  });

  // ── 截图现象（正向空白）复现尝试：均**未能**复现 ──
  //
  // 已尝试：todo/write 插入、session/jobs 插入、逐帧零高度协议事件（team/task /
  // subagent/descriptor）、standard 档 + 40 工具长会话 + 1.5x 大字号。实测始终
  // dist=0、tailResidual=0、btn=false，没有「内容下方大段空白」。
  testWidgets('截图空白未能复现：todo/write 插入后仍收敛到真实末端（documents attempted reproduction）',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 12)),
        mode: WorkStepDisplayMode.detailed,
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'todo 插入');
      replay.record('mount');

      for (var round = 0; round < 3; round++) {
        replay.inject('todo/write', {
          'turn': 1,
          'todos': [
            for (var i = 0; i < 4; i++)
              {'id': 't$i', 'content': '任务 $i', 'status': 'pending'},
          ],
        });
        for (var i = 0; i < 6; i++) {
          await replay.pumpFrame(tag: 'todo$round+$i');
        }
        expect(
          probe.tailResidual!.abs(),
          lessThanOrEqualTo(2),
          reason: 'todo/write 插入后未收敛（若在此变红，说明复现了正向空白）${replay.recent()}',
        );
      }
      expect(probe.jumpButtonVisible, isFalse,
          reason: '跟随态不应出现回底按钮${replay.recent()}');
    } finally {
      await _finish(tester);
    }
  });

  testWidgets('截图空白未能复现：standard 长会话 + 1.5x + 逐帧零高度事件仍收敛',
      (tester) async {
    try {
      final store = await _mount(
        tester,
        _Backend(_runningTurnHistory(tools: 40)),
        mode: WorkStepDisplayMode.standard,
        textScaler: const TextScaler.linear(1.5),
      );
      final probe = _Probe(tester);
      final replay = _Replay(tester, store, probe, 'standard 长会话');
      replay.record('mount');
      for (var i = 0; i < 12; i++) {
        replay.inject(i.isEven ? 'team/task' : 'subagent/descriptor', {
          'turn': 1,
          'id': 'hidden-$i',
        });
        await replay.pumpFrame(tag: 'hidden+$i');
        expect(
          probe.tailResidual!.abs(),
          lessThanOrEqualTo(2),
          reason: '零高度协议事件插入后脱底${replay.recent()}',
        );
      }
      replay.inject('todo/write', {
        'turn': 1,
        'todos': [
          for (var i = 0; i < 4; i++)
            {'id': 't$i', 'content': '任务 $i', 'status': 'pending'},
        ],
      });
      for (var i = 0; i < 8; i++) {
        await replay.pumpFrame(tag: 'todo+$i');
      }
      expect(probe.tailResidual!.abs(), lessThanOrEqualTo(2),
          reason: '长会话 + 1.5x 的 todo/write 插入后未收敛${replay.recent()}');
      expect(probe.jumpButtonVisible, isFalse,
          reason: '跟随态不应出现回底按钮${replay.recent()}');
    } finally {
      await _finish(tester);
    }
  });
}
