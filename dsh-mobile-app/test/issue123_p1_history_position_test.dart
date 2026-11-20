// issue #123 审查 P1（BLOCKING）：新事件把**合法的历史阅读位置**强拉回 center。
//
// 审查报告描述（外部 widget 探针，按描述重建）：
//   - ChatView 是 `CustomScrollView(center: _liveCenterKey)`，center 之前是 `_olderItems`；
//   - 用户真实上翻加载过更早历史后，`pixels` 为负是**合法阅读位置**
//     （审查者实测 `min=-7190, max=0, pixels≈-870`）；
//   - 此时注入一条 `todo/write`，`_clampOverscrollAfterShrink` 只看 `max`
//     （`max>0.5 || pixels>=-0.5` 才 return），于是无条件 `jumpTo(0)`：
//     用户正在读的历史被抢走，而 `intent` 仍是 reading。
//
// 本用例要求（修复前必须失败）：
//   1. 真实上翻分页 → `_olderItems` 非空、`min<0`、`pixels<0`，且**多帧稳定**（不漂移）；
//   2. 注入 `todo/write`（会走 `_onEventLayoutChanged`）后，`pixels` **保持不变**；
//   3. `intent` 仍是 reading；不得出现「强制回底/强制回 center」的校正。
//
// 断言判据按**真实 `[minScrollExtent, maxScrollExtent]`** 写（不是 `pixels>=0`）：
// center 布局下负 pixels 是合法位置，判据是 `rangeError == 0` + 位置保持。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue123_p1_history_position_test.dart

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

const _session = 'session-123-p1';

/// 与生产一致的 live 列表尺寸（不带键盘/安全区），便于 `max≈0` 的短内容几何出现。
const Size _surface = Size(390, 844);

// ── 夹具：长会话 + 分页窗口 ────────────────────────────────────────────────
//
// 20 个已完成短轮次（每轮 4 事件）+ 第 21 轮 52 个 step（每条 step 1 条思考行），
// 共 52 个过程行——初始 REST 只返回最后 50 条事件（真实服务端窗口），
// 更早事件由用户上翻的 `before` 分页取回。
List<Map<String, dynamic>> _history({int steps = 52}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) => events.add({
    'seq': seq++,
    'type': type,
    'data': data,
    'time': 1000 + seq * 10,
  });

  for (var turn = 1; turn <= 20; turn++) {
    add('turn/start', {'turn': turn});
    add('user/message', {
      'messageId': 'u$turn',
      'text': '第 $turn 轮提问',
      'sourceKind': 'user',
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
  // 第 21 轮：运行中（无 turn/end），`steps` 个 step，每个 step 一条思考行 + 一次工具调用。
  // steps=52 → 104 行，触发分批（隐藏 54 行）；steps=20 → 40 行，不触发分批。
  add('turn/start', {'turn': 21});
  add('user/message', {
    'messageId': 'u21',
    'text': '帮我排查滚动问题',
    'sourceKind': 'user',
  });
  for (var step = 1; step <= steps; step++) {
    add('assistant/message', {
      'turn': 21,
      'step': step,
      'messageId': 'r21-$step',
      'text': '',
      'reasoning': '第 $step 步：先确认滚动跟随的当前状态',
      'reasoningChars': 18,
    });
    add('tool/call', {
      'turn': 21,
      'step': step,
      'callId': 'c21-$step',
      'name': 'shell',
      'arguments': 'grep -n scroll lib/screens/chat_screen.dart',
    });
    add('tool/result', {
      'turn': 21,
      'step': step,
      'callId': 'c21-$step',
      'name': 'shell',
      'text': '第 $step 处命中的滚动代码行',
    });
  }
  add('assistant/message', {
    'turn': 21,
    'step': 53,
    'messageId': 'a21-last',
    'text': '继续检查中……',
  });
  return events;
}

class _Backend {
  _Backend(this.history, {this.initialLimit});

  final List<Map<String, dynamic>> history;

  /// 非空时首次加载只返回最后 N 条（真实服务端窗口），更早由 before 分页取回。
  final int? initialLimit;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue123-p1.test'
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
      } else if (initialLimit == null) {
        body = {'ok': true, 'events': history, 'hasMore': false};
      } else {
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

/// 只读测量层：几何直接取真实 ScrollPosition（与生产同一坐标）。
class _Probe {
  _Probe(this.tester);

  final WidgetTester tester;

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

  double get pixels => position.pixels;
  double get minExtent => position.minScrollExtent;
  double get maxExtent => position.maxScrollExtent;

  /// 相对合法区间的越界量（center 布局 min 可为负）。
  double get rangeError {
    final belowMin = minExtent - pixels;
    final aboveMax = pixels - maxExtent;
    if (belowMin > 0) return belowMin;
    if (aboveMax > 0) return aboveMax;
    return 0;
  }

  /// ADR 0035：底部占位已删除；保留 0 读数用于旧日志/断言可读失败信息。
  double get liveBottomGap => 0.0;

  bool get intentFollow {
    final state = tester.state(find.byType(ChatScreen));
    // ignore: avoid_dynamic_calls
    return (state as dynamic).debugPinnedToBottom as bool;
  }
}

class _Replay {
  _Replay(this.tester, this.store, this.probe);

  final WidgetTester tester;
  final AppStore store;
  final _Probe probe;
  final List<String> rows = [];
  int _seq = 9000;

  void record([String? tag]) {
    rows.add(
      '#${rows.length}${tag == null ? '' : '($tag)'} '
      'intent=${probe.intentFollow ? 'follow' : 'reading'} '
      'px=${probe.pixels.toStringAsFixed(1)} '
      'min=${probe.minExtent.toStringAsFixed(1)} '
      'max=${probe.maxExtent.toStringAsFixed(1)} '
      'range=${probe.rangeError.toStringAsFixed(1)}',
    );
  }

  String recent({int count = 12}) {
    final start = rows.length > count ? rows.length - count : 0;
    return '\n${rows.sublist(start).join('\n')}';
  }

  Future<void> pumpFrame({String? tag}) async {
    await tester.pump(const Duration(milliseconds: 16));
    record(tag);
  }

  /// 注入真实 SSE `session/jobs` 帧。
  ///
  /// issue #128 起聊天页不再渲染 JobCard，该帧**不再改变消息区布局**；本用例
  /// 仍保留「不得抢走历史阅读位置 / 不得改成跟随」的回归断言。
  void injectJobs(List<Map<String, dynamic>> jobs) {
    store.injectFrame({
      'type': 'session/jobs',
      'sessionId': _session,
      'jobs': jobs,
    });
  }

  /// 注入一条真实 SSE 事件（同一次挂载内，不重挂）。
  void inject(String type, Map<String, dynamic> data) {
    store.injectFrame({
      'type': 'session/event',
      'sessionId': _session,
      'event': {'seq': _seq++, 'type': type, 'data': data, 'time': _seq * 10},
    });
  }

  /// 真实下滑手势（多步 pan，回到 live 起点）。
  Future<void> dragDown(double distance) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    const step = 45.0;
    var moved = 0.0;
    while (moved < distance) {
      await gesture.moveBy(const Offset(0, -step));
      moved += step;
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 真实上翻手势（多步 pan；不用 `tester.drag` 的单事件位移——单事件在
  /// SelectionArea + lazy 列表下会被吞掉，也无法验证逐帧行为）。
  Future<void> dragUp(double distance) async {
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
}

/// 收尾：卸载页面并释放 store。
///
/// 注入帧会排一个 800ms 的 sessions debounce 计时器（AppStore._debounceSessions）；
/// 释放 store 才能满足 `testWidgets` 的「无待处理计时器」不变量（与产品缺陷无关）。
Future<void> _finish(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  store.dispose();
}

Future<AppStore> _mount(
  WidgetTester tester,
  _Backend backend, {
  WorkStepDisplayMode mode = WorkStepDisplayMode.standard,
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
            key: const ValueKey<String>('issue123-p1'),
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
  testWidgets('P1 上翻加载历史后停在 pixels<0：注入 todo/write 不得抢走阅读位置', (tester) async {
    final backend = _Backend(_history(), initialLimit: 50);
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);
    final replay = _Replay(tester, store, probe);
    replay.record('mount');
    // ignore: avoid_print
    print('[123-P1] mount:${replay.recent(count: 3)}');

    // ── 1. 真实上翻：触发 before 分页，把更早历史补进 center 之前 ──────────
    for (var page = 0; page < 3; page++) {
      await replay.dragUp(540);
      replay.record('dragUp$page');
    }
    // ignore: avoid_print
    print('[123-P1] afterDrags:${replay.recent(count: 4)}');

    // 前提：已经真的分页过（min<0 说明 center 之前有更早历史），且用户停在负像素。
    expect(
      probe.minExtent,
      lessThan(-100),
      reason: '上翻必须真的补进更早历史（min<0 才算 paged）${replay.recent()}',
    );
    expect(
      probe.pixels,
      lessThan(-100),
      reason: '上翻后用户应停在更早历史里（pixels<0 是合法阅读位置）${replay.recent()}',
    );
    expect(probe.rangeError, lessThanOrEqualTo(0.5), reason: '此刻位置必须合法');

    // ── 2. 稳定：12 帧内位置不得自己漂走（意图 = reading） ─────────────
    //
    // issue #123 复核（reviewer-11）：采样必须在**泵帧之前**。旧写法先泵完 12 帧
    // 再采样、然后立刻比较，采样与比较之间没有任何帧/动作 → 差值恒为 0，这条断言
    // 测不出任何漂移（自证式假绿）。
    final before = probe.pixels;
    for (var i = 0; i < 12; i++) {
      await replay.pumpFrame(tag: 'stable$i');
    }
    // ignore: avoid_print
    print('[123-P1] stable:${replay.recent(count: 3)}');
    expect(
      probe.intentFollow,
      isFalse,
      reason: '上翻到历史区后意图必须是 reading${replay.recent()}',
    );
    // 12 帧之间的真实位移：不是回归用例（修复前也不该漂），而是防止将来
    // `rangeClamp`/跟随校正引入「阅读态被悄悄推走」的守卫。
    expect(
      (probe.pixels - before).abs(),
      lessThanOrEqualTo(0.5),
      reason:
          '12 帧稳定期内位置不得漂移（采样 ${before.toStringAsFixed(1)}，'
          '12 帧后 ${probe.pixels.toStringAsFixed(1)}）${replay.recent()}',
    );

    // ── 3. 注入 todo/write：新事件改变布局，但阅读位置必须保持 ───────────
    replay.inject('todo/write', {
      'todos': [
        {'id': 't1', 'content': '确认滚动跟随状态', 'status': 'pending'},
      ],
    });
    for (var i = 0; i < 12; i++) {
      await replay.pumpFrame(tag: 'todo$i');
    }
    // ignore: avoid_print
    print('[123-P1] afterTodo:${replay.recent(count: 6)}');

    expect(
      probe.intentFollow,
      isFalse,
      reason: '注入新事件不得把阅读意图改成跟随${replay.recent()}',
    );
    expect(
      probe.rangeError,
      lessThanOrEqualTo(0.5),
      reason: '注入新事件后位置必须在合法区间内${replay.recent()}',
    );
    expect(
      (probe.pixels - before).abs(),
      lessThanOrEqualTo(1.0),
      reason:
          '用户正在读的历史位置必须保持（注入前 px=${before.toStringAsFixed(1)}，'
          '注入后 px=${probe.pixels.toStringAsFixed(1)}）${replay.recent()}',
    );

    // ── 4. 另一条事件入口：`session/jobs` 帧（#128 之前 JobCard 显隐改变视口高度；
    // 现在不再进入布局，但仍走独立事件分支，防「只在某一种事件上碰巧通过」）。
    replay.injectJobs([
      {'id': 'job-1', 'title': '后台任务', 'status': 'running'},
    ]);
    for (var i = 0; i < 10; i++) {
      await replay.pumpFrame(tag: 'jobs$i');
    }
    // ignore: avoid_print
    print('[123-P1] afterJobs:${replay.recent(count: 4)}');
    expect(
      (probe.pixels - before).abs(),
      lessThanOrEqualTo(1.0),
      reason:
          'session/jobs 布局变化同样不得抢走历史阅读位置'
          '（注入前 px=${before.toStringAsFixed(1)}，注入后 px=${probe.pixels.toStringAsFixed(1)}）'
          '${replay.recent()}',
    );
    expect(
      probe.intentFollow,
      isFalse,
      reason: 'session/jobs 不得把阅读意图改成跟随${replay.recent()}',
    );
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  // issue #123：`atTopAlignment` 的**合法路径**必须仍然成立。
  //
  // 原判据 `pixels <= 0.5` 把「上翻加载过历史后的负 pixels」也当成「顶对齐」，
  // 于是在历史区里也补底部占位。修正为「没有停在更早历史里（pixels >= -0.5）」后，
  // 仍需保证：用户**真的回到 live 起点**、内容矮于一屏、且会话 paged 时，
  // 底部占位（#77/#118 第三种表现）照常生效——否则「短内容停在顶部、下方大片空白」
  // 会以「把负像素一律当顶对齐」之外的另一种方式回归。
  testWidgets('P1b paged 会话回到 live 起点后，短内容底部占位仍必须生效', (tester) async {
    // task-35 后：有隐藏行时不补占位，所以本用例改用「无分批」的夹具（40 行），
    // 单独锁 atLiveWindow 路径（paged + 真正短内容 → 补占位）。
    final backend = _Backend(_history(steps: 20), initialLimit: 50);
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);
    final replay = _Replay(tester, store, probe);

    // 1) 真实上翻分页：paged=true，用户停在更早历史里。
    for (var page = 0; page < 3; page++) {
      await replay.dragUp(540);
    }
    replay.record('paged');
    expect(
      probe.minExtent,
      lessThan(-100),
      reason: '前提：上翻必须真的补进更早历史${replay.recent()}',
    );
    expect(
      probe.pixels,
      lessThan(-100),
      reason: '前提：用户此刻停在更早历史里${replay.recent()}',
    );
    expect(
      probe.liveBottomGap,
      0,
      reason: '停在历史区时不得补底部占位（#76 契约 + #123 修正）${replay.recent()}',
    );

    // 2) 真实下滑回到 live 起点（pixels≈0）。
    await replay.dragDown(1400);
    replay.record('backToLiveTop');
    // ignore: avoid_print
    print(
      '[123-P1b] back:${replay.recent(count: 3)} gap=${probe.liveBottomGap}',
    );
    expect(
      probe.pixels,
      greaterThanOrEqualTo(-0.5),
      reason: '真实下滑后必须回到 live 起点之后${replay.recent()}',
    );

    // 3) 让会话短于一屏并触发一次布局变化（真实事件入口 → 占位重测）。
    //    先注入 turn/end 折叠本轮过程段，再注入一条 todo/write 触发布局重测。
    replay.inject('turn/end', {
      'turn': 21,
      'reason': {'kind': 'completed'},
    });
    for (var i = 0; i < 8; i++) {
      await replay.pumpFrame(tag: 'end$i');
    }
    replay.inject('todo/write', {
      'todos': [
        {'id': 't1', 'content': '确认底部占位', 'status': 'pending'},
      ],
    });
    for (var i = 0; i < 8; i++) {
      await replay.pumpFrame(tag: 'todo$i');
    }
    // ignore: avoid_print
    print(
      '[123-P1b] final:${replay.recent(count: 6)} '
      'gap=${probe.liveBottomGap}',
    );
    expect(
      probe.maxExtent,
      lessThan(1),
      reason: '前提：折叠后内容应已矮于一屏${replay.recent()}',
    );
    expect(
      probe.liveBottomGap,
      0,
      reason: 'ADR 0035：短内容顶对齐，不再补底部占位${replay.recent()}',
    );
    expect(
      probe.pixels,
      greaterThanOrEqualTo(-0.5),
      reason: '折叠变短后位置必须仍在 live 区间${replay.recent()}',
    );
    expect(probe.rangeError, lessThanOrEqualTo(0.5), reason: '位置必须合法');
    await _finish(tester, store);
  });
}
