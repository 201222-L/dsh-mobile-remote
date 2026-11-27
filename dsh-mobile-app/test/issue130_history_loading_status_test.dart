// issue #130 Phase 1：上翻历史加载的顶部提示（widget 回归）。
//
// 需求口径（GitLab #130 + UI 验收规范）：
//   - 状态行是 center **之前的独立首 sliver**（`SliverPadding → SliverToBoxAdapter`），
//     固定高 36dp，位于 older 列表视觉顶部；不是 `_olderItems` 的子项、不是 pinned header；
//   - 四态：loading（转圈 +「正在加载更早消息…」）/ failed（「更早消息加载失败，点此重试」）/
//     exhausted（「没有更早消息了」，降级为「更早历史不可恢复」）/ idle（「继续上滑加载更早」）；
//   - `_loadingMore` 在 await 之前 setState → 转圈在请求开始的那一帧即出现；
//   - 失败后 `_olderLoadFailed` 门禁拦住 80px 自动重发，只允许点状态行重试；
//   - 短会话（首屏即全部）不显示状态行；行存在性固定，之后只换文字/图标；
//   - 与既有自动加载共存：快速连续上翻不重复请求；成功 prepend 后阅读位置/触点不跳；
//   - 320dp / 深色 / 1.5× 字号不溢出。
//
// 说明（为什么 idle 可见态要特殊构造）：到顶 80px 内会自动触发加载，因此状态行真正
// 滚进视口时通常已是 loading。idle 的可见态用「一页只含隐藏事件（step/start）」复现：
// `_buildInto` 直接跳过、不新增可见高度，状态行留在视觉顶部且请求已完成 → idle 可见、
// 可点。该页在真实服务端同样可能出现（隐藏事件不代表没有历史），不是测试专用后门。
//
// 精确重跑：
//   cd dsh-mobile-app && flutter test --no-pub test/issue130_history_loading_status_test.dart

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String _session = 'session-130';
const Size _surface = Size(390, 844);
const String _loadingLabel = '正在加载更早消息…';
const String _exhaustedLabel = '没有更早消息了';
const String _degradedLabel = '更早历史不可恢复';
const String _idleLabel = '继续上滑加载更早';
const String _failedLabel = '更早消息加载失败，点此重试';

// ── 夹具：30 个完整短轮次（4 事件/轮，seq 1..120） ─────────────────────────
List<Map<String, dynamic>> _history({int turns = 30}) {
  final events = <Map<String, dynamic>>[];
  var seq = 1;
  void add(String type, Map<String, dynamic> data) => events.add({
    'seq': seq++,
    'type': type,
    'data': data,
    'time': 1000 + seq * 10,
  });
  for (var turn = 1; turn <= turns; turn++) {
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
  return events;
}

/// 真实 `/api/history` 分页夹具：初始窗口取最后 [initialWindow] 条；
/// `before` 页可被挂起/失败，用来验证即时转圈、失败门禁与重试恢复。
class _HistoryBackend {
  _HistoryBackend(this.history, {this.initialWindow = 40});

  final List<Map<String, dynamic>> history;
  final int initialWindow;

  int historyCalls = 0;
  int beforeCalls = 0;
  final List<String> beforeCursors = [];
  bool holdBefore = false;

  /// 下一次 before 响应的自定义构造（用于「一页只含隐藏事件」的 idle 可见场景）。
  http.Response Function(int before, int limit)? pageOverride;

  Completer<http.Response>? _pending;
  int? _pendingCursor;
  int _pendingLimit = 30;

  late final Api api = Api(client: MockClient(_handle))
    ..baseUrl = 'http://issue130.test'
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

  bool get hasPendingBefore => _pending != null && !_pending!.isCompleted;

  /// 正常返回挂起的那次 before 分页；[hasMore] 由测试显式给定（便于锁四态）。
  ///
  /// 同步完成 Completer：后续由用例自己的固定 `pump` 驱动微任务/重建。
  /// 不在这里 `pumpEventQueue()`——`testWidgets` 是 fake-async，等它会永久挂起。
  void completeBefore({required bool hasMore}) {
    final pending = _pending;
    if (pending == null || pending.isCompleted) {
      fail('没有挂起的 before 请求可完成');
    }
    _pending = null;
    final override = pageOverride;
    pageOverride = null;
    if (override != null) {
      pending.complete(override(_pendingCursor!, _pendingLimit));
      return;
    }
    // hasMore=false 表示真的到顶：真实服务端此时不会再返回事件（空页），
    // 这样 `_noMoreHistory` 才会置位、后续上翻不再发请求。
    pending.complete(
      hasMore
          ? _pageResponse(_pendingCursor!, _pendingLimit, hasMore: true)
          : _json({'ok': true, 'events': <Object>[], 'hasMore': false}),
    );
  }

  /// 模拟离线/请求失败：让挂起请求以异常结束（生产 `_prependOlderPage` 会捕获）。
  void failPendingBefore() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) {
      fail('没有挂起的 before 请求可失败');
    }
    _pending = null;
    pending.completeError(http.ClientException('offline (issue #130 test)'));
  }

  /// 下一页只含隐藏事件（`step/start`）：`_buildInto` 提前返回 → 不新增可见高度，
  /// 状态行仍停在视觉顶部，用于断言 idle 的可见态与点击入口。
  http.Response hiddenOnlyPage(int before, int limit) => _json({
    'ok': true,
    'events': [
      {
        'seq': before - 1,
        'type': 'step/start',
        'data': {'turn': 1, 'step': 1},
        'time': 1000,
      },
    ],
    'hasMore': true,
  });

  /// 空页 + degraded：到顶且历史降级 → 状态行应显示「更早历史不可恢复」。
  http.Response exhaustedDegradedPage(int before, int limit) => _json({
    'ok': true,
    'degraded': true,
    'events': <Object>[],
    'hasMore': false,
  });

  http.Response _pageResponse(int before, int limit, {required bool hasMore}) {
    final preceding = history.where((e) => (e['seq'] as int) < before).toList();
    return _json({
      'ok': true,
      'events': preceding.length > limit
          ? preceding.sublist(preceding.length - limit)
          : preceding,
      'hasMore': hasMore,
    });
  }

  http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    if (path == '/m/api/history') {
      historyCalls += 1;
      final params = request.url.queryParameters;
      final limit = int.tryParse(params['limit'] ?? '') ?? 50;
      if (params.containsKey('before')) {
        beforeCalls += 1;
        final before = int.tryParse(params['before'] ?? '') ?? 0;
        beforeCursors.add(params['before'] ?? '');
        if (holdBefore) {
          final pending = Completer<http.Response>();
          _pending = pending;
          _pendingCursor = before;
          _pendingLimit = limit;
          return pending.future;
        }
        return _pageResponse(before, limit, hasMore: false);
      }
      if (params.containsKey('after')) {
        return _json({'ok': true, 'events': <Object>[], 'hasMore': false});
      }
      final window = history.length > initialWindow
          ? history.sublist(history.length - initialWindow)
          : history;
      return _json({
        'ok': true,
        'events': window,
        'hasMore': history.length > window.length,
      });
    }
    // 其余（usage/turn-outline/session-config/todos…）给空成功响应。
    return _json({'ok': true});
  }
}

// ── 只读探针 ───────────────────────────────────────────────────────────────
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

  dynamic get _state => tester.state(find.byType(ChatScreen));

  OlderHistoryStatus? get status =>
      // ignore: avoid_dynamic_calls
      _state.debugOlderHistoryStatus as OlderHistoryStatus?;

  bool get rowVisible =>
      // ignore: avoid_dynamic_calls
      _state.debugOlderStatusRowVisible as bool;

  bool get loadingMore =>
      // ignore: avoid_dynamic_calls
      _state.debugLoadingMore as bool;

  bool get loadFailed =>
      // ignore: avoid_dynamic_calls
      _state.debugOlderLoadFailed as bool;

  bool get atTop => pixels - minExtent <= 1.0;

  String geometry() =>
      'px=${pixels.toStringAsFixed(1)} '
      'min=${minExtent.toStringAsFixed(1)} '
      'status=$status rowVisible=$rowVisible loading=$loadingMore '
      'failed=$loadFailed';

  Finder get statusRow => find.byKey(olderHistoryStatusRowKey);

  /// 状态行当前高度（必须恰好在视口内/已构建）。
  double statusRowHeight() {
    expect(statusRow, findsOneWidget, reason: '状态行应已构建（视觉顶部）：${geometry()}');
    return tester.getSize(statusRow).height;
  }
}

// ── 手势（逐帧真实 pan；单事件 `tester.drag` 在 SelectionArea + lazy 列表里会被吞）──
/// 有界 settle：固定 pump，最多 [maxFrames] 帧；不依赖 `pumpAndSettle` 的无限动画语义。
Future<void> _pumpUntilIdle(WidgetTester tester, {int maxFrames = 80}) async {
  for (var i = 0; i < maxFrames; i++) {
    if (!tester.binding.hasScheduledFrame) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

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

/// issue #130 P2：真实上翻到「距视觉顶部 [target] px」停手（不拖到顶）。
///
/// 粗步进靠近后改用小步进，最后停顿消除惯性；用于复现“触发带 50–80px 内停手”的
/// 真实场景（此时首 sliver 状态行仍在视口上方）。
Future<void> _dragToDistanceFromTop(
  WidgetTester tester,
  _Probe probe,
  double target,
) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(CustomScrollView)),
  );
  await tester.pump(const Duration(milliseconds: 20));
  for (var i = 0; i < 400; i++) {
    final distance = probe.pixels - probe.minExtent;
    if (distance <= target) break;
    final remaining = distance - target;
    final step = remaining > 90 ? 90.0 : remaining.clamp(1.0, 20.0);
    await gesture.moveBy(Offset(0, step));
    await tester.pump(const Duration(milliseconds: 16));
  }
  // 停手消除 fling 惯性（否则会继续冲到顶部）。
  await tester.pump(const Duration(milliseconds: 160));
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

/// 真实上翻到视觉顶部（逐帧手势，直到 `pixels == min`）。
Future<void> _dragToTop(WidgetTester tester, _Probe probe) async {
  for (var i = 0; i < 40; i++) {
    if (probe.atTop) return;
    await _dragUp(tester, 500);
  }
  fail('40 次上翻后仍未到视觉顶部：${probe.geometry()}');
}

Future<void> _finish(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 900));
  store.dispose();
}

Future<AppStore> _mount(
  WidgetTester tester,
  _HistoryBackend backend, {
  Size size = _surface,
  bool dark = false,
  double textScale = 1.0,
}) async {
  final store = AppStore()
    ..sessionId = _session
    ..sessions = [Session(id: _session, title: 'S', cwd: null, createdAt: 1)]
    ..stepDisplayMode = WorkStepDisplayMode.standard
    ..turnFoldTiming = TurnFoldTiming.afterAnswer;
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? DshTheme.forSkin(DshSkin.dsh, Brightness.dark) : null,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: ChatScreen(
            key: const ValueKey<String>('issue130'),
            store: store,
            apiClient: backend.api,
            onTitleChanged: () {},
            // 首屏自动补拉会自己发 before 请求；本用例要精确控制分页时机。
            autoFillFirstScreen: false,
          ),
        ),
      ),
    ),
  );
  // 有界 settle：固定 pump 直到没有待调度帧（不用 pumpAndSettle——转圈是无限动画，
  // 一旦出现会把它卡到默认 10 分钟超时）。
  await tester.pump(const Duration(milliseconds: 350));
  await _pumpUntilIdle(tester);
  return store;
}

void main() {
  group('olderHistoryStatusFor（四态判定纯函数）', () {
    test('未锁定行/未加载完返回 null；loading 与 failed 优先于到顶', () {
      OlderHistoryStatus? f({
        bool loaded = true,
        bool loading = false,
        bool failed = false,
        bool hasMore = true,
        bool noMore = false,
      }) => olderHistoryStatusFor(
        loaded: loaded,
        loadingMore: loading,
        loadFailed: failed,
        hasMore: hasMore,
        noMore: noMore,
      );
      expect(f(loaded: false), isNull);
      expect(
        f(loading: true, failed: true, hasMore: false, noMore: true),
        OlderHistoryStatus.loading,
      );
      expect(
        f(failed: true, hasMore: false, noMore: true),
        OlderHistoryStatus.failed,
      );
      expect(f(hasMore: true), OlderHistoryStatus.idle);
      expect(f(hasMore: false), OlderHistoryStatus.exhausted);
      expect(f(hasMore: true, noMore: true), OlderHistoryStatus.exhausted);
    });
  });

  testWidgets('loading 只 pump 触发帧即出现；快速上翻不重复请求；到顶后不再请求', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);

    // ── 0. 初始：长会话行存在性锁定（idle），尚未请求 ───────────────────────
    expect(probe.rowVisible, isTrue, reason: '首屏 hasMore=true 时行存在性锁定');
    expect(probe.status, OlderHistoryStatus.idle);
    expect(backend.beforeCalls, 0);

    // ── 1. 自动触发：只 pump 触发那一帧，loading 必须已就位（不等请求结束） ──
    backend.holdBefore = true;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    await tester.pump();
    var triggered = false;
    for (var i = 0; i < 200; i++) {
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 16));
      if (backend.beforeCalls == 1) {
        triggered = true;
        break;
      }
    }
    expect(triggered, isTrue, reason: '上翻到距顶 80px 内必须触发一次 before 请求');
    // 触发帧之后没有额外 pump：setState 必须已经在请求开始前完成。
    expect(
      probe.loadingMore,
      isTrue,
      reason: '触发那一帧 loading 必须为 true（转圈不能等请求结束）',
    );
    expect(probe.status, OlderHistoryStatus.loading);
    expect(backend.hasPendingBefore, isTrue);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // 真实手势走到视觉顶部：状态行可见、转圈 + 文案、固定高度。
    await _dragToTop(tester, probe);
    expect(probe.atTop, isTrue, reason: probe.geometry());
    expect(find.text(_loadingLabel), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final rowHeight = probe.statusRowHeight();
    expect(rowHeight, olderHistoryStatusRowHeight);

    // ── 2. 加载在途快速连续上翻：不得重复请求 ──────────────────────────────
    await _dragUp(tester, 260);
    await _dragUp(tester, 260);
    expect(
      backend.beforeCalls,
      1,
      reason: '加载在途的快速上翻不得再发请求（${backend.beforeCursors}）',
    );
    expect(find.text(_loadingLabel), findsOneWidget);
    expect(probe.statusRowHeight(), rowHeight);

    // ── 3. 最后一页 hasMore=false → exhausted；行高度不变 ──────────────────
    backend.completeBefore(hasMore: false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(probe.loadingMore, isFalse, reason: '响应完成后 loading 必须复位');
    await _dragToTop(tester, probe);
    expect(probe.status, OlderHistoryStatus.exhausted);
    expect(find.text(_exhaustedLabel), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(probe.statusRowHeight(), rowHeight);

    // ── 4. 到顶后继续上翻：不再发必然空的请求 ──────────────────────────────
    backend.holdBefore = false;
    await _dragUp(tester, 300);
    await _dragUp(tester, 300);
    expect(
      backend.beforeCalls,
      1,
      reason: '已确认到顶后继续上翻不得再请求（${backend.beforeCursors}）',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('idle 可见且可点整行触发（一页隐藏事件后仍在视觉顶部）', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);

    backend.holdBefore = true;
    await _dragToTop(tester, probe);
    expect(find.text(_loadingLabel), findsOneWidget);
    expect(backend.beforeCalls, 1);

    // 一页只含隐藏事件：不新增可见高度，状态行留在视觉顶部；请求完成后显示 idle。
    backend.pageOverride = backend.hiddenOnlyPage;
    backend.completeBefore(hasMore: true);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(probe.loadingMore, isFalse);
    expect(probe.status, OlderHistoryStatus.idle);
    expect(
      find.text(_idleLabel),
      findsOneWidget,
      reason: 'idle 可见态：加载完成后状态行应显示“继续上滑加载更早”',
    );
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);

    // 点整行 = 手动触发同一实现（只 pump 一帧出现 loading）。
    backend.holdBefore = true;
    await tester.tap(probe.statusRow);
    await tester.pump();
    expect(backend.beforeCalls, 2, reason: backend.beforeCursors.join(','));
    expect(
      probe.status,
      OlderHistoryStatus.loading,
      reason: '点行触发后第一帧就必须是 loading',
    );
    expect(find.text(_loadingLabel), findsOneWidget);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);

    // 收尾：把在途请求放掉，避免 Api 的 15s 超时计时器残留到断言之外。
    backend.completeBefore(hasMore: false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('P2：触发带内停手时顶部 pill 在屏幕可见；到顶后 pill 隐藏、sliver 行显示', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);
    final viewport = tester.getRect(find.byType(CustomScrollView));

    // 只上翻到距顶 60px（触发带 50–80px），不拖到顶。
    backend.holdBefore = true;
    await _dragToDistanceFromTop(tester, probe, 60);
    final distance = probe.pixels - probe.minExtent;
    expect(backend.beforeCalls, 1, reason: '80px 内应触发一次 before 请求');
    expect(
      distance,
      greaterThan(olderHistoryStatusRowHeight),
      reason: '前提：首 sliver 状态行此时应完全在视口上方（${probe.geometry()}）',
    );
    expect(distance, lessThan(80));

    // 顶部 pill 必须真实可见（屏幕坐标落在消息视口内），而不是只改 model。
    final pill = find.byKey(olderLoadingOverlayKey);
    expect(pill, findsOneWidget, reason: '触发带内停手必须能看到 loading pill');
    final pillRect = tester.getRect(pill);
    expect(
      pillRect.top,
      greaterThanOrEqualTo(viewport.top - 0.5),
      reason: 'pill 不得被 AppBar 遮住（${pillRect.top} vs ${viewport.top}）',
    );
    expect(
      pillRect.bottom,
      lessThanOrEqualTo(viewport.bottom + 0.5),
      reason: 'pill 必须在消息视口内（${pillRect.bottom} vs ${viewport.bottom}）',
    );
    expect(pillRect.width, greaterThan(0));
    // 此时首 sliver 行仍在视口上方（不能是它在显示 loading）。
    // 反向 sliver 可能还没被懒构建——未构建同样等于不可见。
    if (probe.statusRow.evaluate().isNotEmpty) {
      final rowOffscreen = tester.getRect(probe.statusRow);
      expect(
        rowOffscreen.bottom,
        lessThanOrEqualTo(viewport.top + 0.5),
        reason: '状态行应仍在视口上方（bottom=${rowOffscreen.bottom}）',
      );
    }

    // overlay 不改变滚动 extent（不是 sliver、不参与布局）。
    final extentWhilePill =
        probe.position.maxScrollExtent - probe.position.minScrollExtent;

    // ── 交接区间：继续滑到距顶 30–35px 停手（复审指出的漏测点）──────────────
    // 状态行只露出底部几像素，转圈/文案仍被裁掉；pill 必须继续可见。
    await _dragToDistanceFromTop(tester, probe, 32);
    final handoffDistance = probe.pixels - probe.minExtent;
    expect(handoffDistance, lessThan(36));
    expect(handoffDistance, greaterThan(8));
    final pillAtHandoff = find.byKey(olderLoadingOverlayKey);
    expect(
      pillAtHandoff,
      findsOneWidget,
      reason: '距顶 30–35px 时状态行内容仍被裁，pill 不得提前隐藏',
    );
    final pillHandoffRect = tester.getRect(pillAtHandoff);
    expect(
      pillHandoffRect.top,
      greaterThanOrEqualTo(viewport.top - 0.5),
    );
    expect(
      pillHandoffRect.bottom,
      lessThanOrEqualTo(viewport.bottom + 0.5),
    );
    expect(
      backend.beforeCalls,
      1,
      reason: '交接区间继续上翻不得重复请求（${backend.beforeCursors}）',
    );

    // 再滑到顶 0px：pill 隐藏，首 sliver 行的转圈与文案都进入视口；请求数仍 1。
    await _dragToTop(tester, probe);
    expect(find.byKey(olderLoadingOverlayKey), findsNothing, reason: '到顶后不得双显');
    final rowAtTop = tester.getRect(probe.statusRow);
    expect(rowAtTop.top, greaterThanOrEqualTo(viewport.top - 0.5));
    expect(rowAtTop.bottom, lessThanOrEqualTo(viewport.bottom));
    final rowLabelRect = tester.getRect(
      find.descendant(
        of: probe.statusRow,
        matching: find.text(_loadingLabel),
      ),
    );
    expect(
      rowLabelRect.top,
      greaterThanOrEqualTo(viewport.top - 0.5),
      reason: '状态行文案必须真正进入视口（不被顶部裁掉）',
    );
    expect(rowLabelRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
    final rowSpinnerRect = tester.getRect(
      find.descendant(
        of: probe.statusRow,
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(rowSpinnerRect.top, greaterThanOrEqualTo(viewport.top - 0.5));
    expect(
      backend.beforeCalls,
      1,
      reason: '继续上翻不得重复请求（${backend.beforeCursors}）',
    );
    expect(
      probe.position.maxScrollExtent - probe.position.minScrollExtent,
      extentWhilePill,
      reason: 'pill 不得改变滚动 extent',
    );

    backend.completeBefore(hasMore: false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(olderLoadingOverlayKey), findsNothing);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('失败 → failed 态；80px 自动触发被门禁拦住；点行重试可恢复', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);

    backend.holdBefore = true;
    await _dragToTop(tester, probe);
    expect(backend.beforeCalls, 1);
    expect(find.text(_loadingLabel), findsOneWidget);

    // 失败（离线/500 等价）：请求以异常结束。
    backend.failPendingBefore();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(probe.loadingMore, isFalse, reason: '失败后不得卡在 loading');
    expect(probe.loadFailed, isTrue, reason: '失败必须置 `_olderLoadFailed` 门禁');
    expect(probe.status, OlderHistoryStatus.failed);
    expect(find.text(_failedLabel), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);

    // 失败后继续自动上翻：门禁拦住，只允许点重试。
    await _dragUp(tester, 300);
    await _dragUp(tester, 300);
    expect(
      backend.beforeCalls,
      1,
      reason: '失败后自动触发不得连续重发（${backend.beforeCursors}）',
    );
    expect(find.text(_failedLabel), findsOneWidget);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);

    // 点行重试：第一帧 loading，成功后回到 exhausted。
    backend.holdBefore = true;
    await tester.tap(probe.statusRow);
    await tester.pump();
    expect(backend.beforeCalls, 2, reason: backend.beforeCursors.join(','));
    expect(probe.status, OlderHistoryStatus.loading);
    expect(probe.loadFailed, isFalse, reason: '重试开始应清掉失败门禁');
    expect(find.text(_loadingLabel), findsOneWidget);
    backend.completeBefore(hasMore: false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await _dragToTop(tester, probe);
    expect(probe.status, OlderHistoryStatus.exhausted);
    expect(find.text(_exhaustedLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('成功 prepend 后阅读位置与触点不跳（状态行等高、内容插入不推动视口）', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);

    // 先加载一页（挂起），上翻到顶；完成后新页在顶，继续上翻会触发第二页。
    backend.holdBefore = true;
    await _dragToTop(tester, probe);
    expect(backend.beforeCalls, 1);
    backend.completeBefore(hasMore: true);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));

    // 继续上翻到新顶：第二页在途（loading），此时记录已加载消息的位置。
    await _dragToTop(tester, probe);
    // 等惯性/懒构建估算稳定（固定 pump，不用 pumpAndSettle）。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(backend.beforeCalls, 2, reason: backend.beforeCursors.join(','));
    expect(find.text(_loadingLabel), findsOneWidget);
    final message = find.text('第 13 轮回答');
    expect(message, findsOneWidget, reason: '夹具前提：第一页补回了第 13 轮（seq 51..80）');
    final topBefore = tester.getTopLeft(message).dy;
    final pixelsBefore = probe.pixels;
    final minBefore = probe.minExtent;
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);

    // 完成第二页：新内容插到状态行下方（远离 center），已加载消息与 pixels 不动。
    backend.completeBefore(hasMore: true);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final topAfter = tester.getTopLeft(message).dy;
    expect(
      (probe.pixels - pixelsBefore).abs(),
      lessThanOrEqualTo(0.5),
      reason: '补页不得改变阅读位置（center 锚点不重排已构建子项）',
    );
    // 触点/滚动偏移必须严格不跳（center 锚点不重排已构建子项）。
    expect(probe.pixels, pixelsBefore, reason: '补页不得改变滚动偏移（触点位置）');
    // 消息屏幕位置允许既有的 SliverList 懒估算修正（ADR 0035 实施记录：历史侧
    // 只构建少量子项时估算值会随后修正），但不得出现整页级跳动。
    final contentShift = (topAfter - topBefore).abs();
    expect(
      contentShift,
      lessThanOrEqualTo(16.0),
      reason:
          '补页只允许既有 lazy 估算修正的亚行级位移，不得整页跳动'
          '（${topBefore.toStringAsFixed(1)} → ${topAfter.toStringAsFixed(1)}）',
    );
    expect(contentShift, lessThan(olderHistoryStatusRowHeight));
    // 滚动范围只向上增长（新增更早内容），当前 pixels 仍是合法阅读位置。
    expect(probe.minExtent, lessThan(minBefore - 20));
    expect(probe.pixels, greaterThanOrEqualTo(probe.minExtent - 0.5));
    expect(probe.status, OlderHistoryStatus.idle);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('短会话（首屏即全部）不显示状态行，也不发 before 请求', (tester) async {
    final history = _history(turns: 6);
    final backend = _HistoryBackend(history, initialWindow: history.length);
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);

    expect(probe.rowVisible, isFalse, reason: 'hasMore=false 的首屏即全部，不应出现状态行');
    expect(probe.status, isNull);
    expect(probe.statusRow, findsNothing);

    await _dragUp(tester, 240);
    await _dragUp(tester, 240);
    expect(backend.beforeCalls, 0, reason: '短会话上翻不得请求更早历史');
    expect(probe.statusRow, findsNothing);
    expect(probe.status, isNull);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('degraded：到顶且历史降级 → “更早历史不可恢复”', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(tester, backend);
    final probe = _Probe(tester);

    backend.holdBefore = true;
    await _dragToTop(tester, probe);
    expect(find.text(_loadingLabel), findsOneWidget);
    backend.pageOverride = backend.exhaustedDegradedPage;
    backend.completeBefore(hasMore: false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(probe.status, OlderHistoryStatus.exhausted);
    expect(
      find.descendant(of: probe.statusRow, matching: find.text(_degradedLabel)),
      findsOneWidget,
      reason: '降级会话到顶时状态行应显示“更早历史不可恢复”',
    );
    expect(find.text(_exhaustedLabel), findsNothing);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);
    expect(tester.takeException(), isNull);
    await _finish(tester, store);
  });

  testWidgets('320dp + 深色 + 1.5× 字号：四态都不溢出且高度固定', (tester) async {
    final backend = _HistoryBackend(_history());
    final store = await _mount(
      tester,
      backend,
      size: const Size(320, 640),
      dark: true,
      textScale: 1.5,
    );
    final probe = _Probe(tester);

    // loading
    backend.holdBefore = true;
    await _dragToTop(tester, probe);
    expect(find.text(_loadingLabel), findsOneWidget);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);
    expect(tester.takeException(), isNull, reason: '加载中 320dp/1.5× 不得溢出');

    // idle（隐藏事件页：不新增可见高度，行留在顶部）
    backend.pageOverride = backend.hiddenOnlyPage;
    backend.completeBefore(hasMore: true);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(_idleLabel), findsOneWidget);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);
    expect(tester.takeException(), isNull, reason: 'idle 320dp/1.5× 不得溢出');

    // failed（最长文案）
    backend.holdBefore = true;
    await tester.tap(probe.statusRow);
    await tester.pump();
    expect(find.text(_loadingLabel), findsOneWidget);
    backend.failPendingBefore();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(_failedLabel), findsOneWidget);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);
    expect(tester.takeException(), isNull, reason: 'failed 320dp/1.5× 不得溢出');

    // exhausted
    backend.holdBefore = true;
    await tester.tap(probe.statusRow);
    await tester.pump();
    expect(find.text(_loadingLabel), findsOneWidget);
    backend.completeBefore(hasMore: false);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await _dragToTop(tester, probe);
    expect(find.text(_exhaustedLabel), findsOneWidget);
    expect(probe.statusRowHeight(), olderHistoryStatusRowHeight);
    expect(tester.takeException(), isNull, reason: 'exhausted 320dp/1.5× 不得溢出');

    // 深色主题确实生效（状态行文字/图标取主题 ink 色系）。
    final theme = Theme.of(tester.element(find.byType(ChatScreen)));
    expect(theme.brightness, Brightness.dark);
    await _finish(tester, store);
  });
}
