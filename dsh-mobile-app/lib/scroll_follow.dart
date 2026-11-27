// issue #114（§5.2）：滚动跟随意图与「布局后校正」的唯一 owner。
//
// 背景：此前「跟随意图、用户拖拽、待执行回底、多帧收敛」散在 ChatScreen 的多个独立
// bool 与多处帧后回调里（_pinnedToBottom / _userDragActive / _followBottomScheduled /
// _settledFollowScheduled / _settleToBottom / _scrollToBottom），任何一处漏掉守卫或
// 帧调度都会重现 #77/#89/#103 类问题。本文件把这些状态收口为一个可单测的协调器：
//
// 1. **意图只由用户动作/显式导航改变**：near-bottom、回底按钮显隐只是派生的展示量，
//    不允许反过来改写意图（§5.2）。
// 2. **一切延后/分帧校正自己保证有帧**：owner 在有待执行校正时调用 [ensureFrame]；
//    生产实现必须「注册 post-frame 回调 + 确保帧被调度」（`addPostFrameCallback`
//    本身不调度帧，见 issue #114 A2 实测）。
// 3. **校正执行时重查意图**：拖拽、阅读态、会话/导航世代在 takeCorrection 里逐项
//    复核；拖拽中的校正会直接作废（用户手势优先）。收敛有界（默认 4 次），合并去重，
//    收敛后不再排帧（无空闲自激）。
//
// 本文件不 import Flutter，生产与单测/Widget 回放穿同一 seam。
library;

/// 一次滚动几何快照（生产从 ScrollPosition/ScrollMetrics 读，单测直接构造）。
class ScrollGeometry {
  const ScrollGeometry({
    required this.pixels,
    required this.minExtent,
    required this.maxExtent,
    required this.viewportDimension,
  });

  final double pixels;
  final double minExtent;
  final double maxExtent;
  final double viewportDimension;

  /// 当前 pixels 到真实滚动末端的距离（负值 = 已越过末端，平台弹性/估值外）。
  double get distanceToEnd => maxExtent - pixels;

  /// 相对合法 `[minExtent, maxExtent]` 的越界量（center 布局的 min 可以为负）。
  double get rangeError {
    final belowMin = minExtent - pixels;
    final aboveMax = pixels - maxExtent;
    if (belowMin > 0) return belowMin;
    if (aboveMax > 0) return aboveMax;
    return 0;
  }

  @override
  String toString() =>
      'ScrollGeometry(pixels=$pixels, min=$minExtent, max=$maxExtent)';
}

/// 跟随意图（§3.2）：只表达用户想不想跟最新，不表达几何。
enum FollowIntent {
  /// 跟随最新：内容/布局变化后允许校正到真实末端。
  followLatest,

  /// 用户阅读/显式轮次定位：任何自动校正都不得抢走位置。
  reading,
}

/// 校正原因。合并时按「越显式越优先」选择，预算取较大者。
enum CorrectionReason {
  /// 内部再收敛（例如一次 jump 后 lazy extent 修正）；由 owner 预算驱动，外部一般不用。
  settle,

  /// 布局变短后的**越界夹回**（issue #123）：`pixels` 落到 `[minExtent, maxExtent]`
  /// 之外。语义是机械修正而不是「跟随最新」——目标 = 当前 pixels 夹回合法区间，
  /// **不是** `maxExtent`（详见 [ScrollFollowCoordinator.requestRangeClamp]）。
  rangeClamp,

  /// 新事件 / 同一过程条目内部增高 / 展开收起 / 异步详情 / 活动条显隐等布局版本变化。
  contentLayout,

  /// 点击「回到底部」按钮。
  explicitBackToBottom,

  /// 初始打开、回 live、发送消息等强制定位。
  forcedPosition,
}

int _reasonRank(CorrectionReason reason) => switch (reason) {
  CorrectionReason.settle => 1,
  CorrectionReason.rangeClamp => 2,
  CorrectionReason.contentLayout => 3,
  CorrectionReason.explicitBackToBottom => 4,
  CorrectionReason.forcedPosition => 5,
};

/// 一次待执行的校正决策（适配器拿到后执行 jumpTo，再回报 [ScrollFollowCoordinator.noteCorrectionApplied]）。
class ScrollCorrection {
  const ScrollCorrection({
    required this.targetPixels,
    required this.reason,
    required this.attempt,
    required this.budget,
    required this.generation,
  });

  /// 目标滚动偏移（通常 = 当前 maxScrollExtent）。
  final double targetPixels;
  final CorrectionReason reason;

  /// 本批已执行过的次数（0 起）。
  final int attempt;

  /// 本批允许的最大执行次数。
  final int budget;

  /// 安排这次校正时的导航/会话世代；执行时与该值不符即作废。
  final int generation;

  @override
  String toString() =>
      'ScrollCorrection(target=$targetPixels, reason=${reason.name}, '
      'attempt=$attempt/$budget, gen=$generation)';
}

class _PendingCorrection {
  _PendingCorrection({
    required this.reason,
    required this.budget,
    required this.generation,
  });

  CorrectionReason reason;
  int budget;
  int generation;
  int attempt = 0;
}

/// 滚动跟随的唯一 owner。
///
/// 使用方（ChatScreen）负责：
/// - 把 ScrollPosition/ScrollMetricsNotification 转成 [ScrollGeometry] 并调用
///   [onMetrics]/[onUserScrollStart]/[onUserScrollUpdate]/[onUserScrollEnd]；
/// - 在内容/布局变化、显式回底、强制定位时调用对应的 `request*`；
/// - 收到 [ensureFrame] 回调后，注册一帧后的执行器：在帧后调用 [takeCorrection]，
///   非 null 就 `jumpTo(decision.targetPixels)` 再调用 [noteCorrectionApplied]；
/// - 所有**程序性**滚动（jumpTo/animateTo/ensureVisible）前后用
///   [beginProgrammaticScroll]/[endProgrammaticScroll] 包住，避免它们的 ScrollEnd
///   被误判成用户手势结束。
class ScrollFollowCoordinator {
  ScrollFollowCoordinator({
    required this.ensureFrame,
    this.nearBottomThreshold = 160,
    this.convergeTolerance = 1,
    this.defaultBudget = 4,
  });

  /// 帧调度出口：owner 需要「帧后测量」时必须回调这里。
  /// 生产实现要同时满足：注册 post-frame 回调 + 确保下一帧被调度。
  final void Function() ensureFrame;

  /// 「接近底部」的**产品展示**阈值：只用于回底按钮/刻度轨显隐，不用于意图判定。
  /// 维护者口径（#114 task-11）：意图必须「真正到底」才钉住；160px 只是按钮产品阈值。
  final double nearBottomThreshold;

  /// 收敛容差（logical px）：`|distanceToEnd| <= tolerance` 且无越界即视为已到达。
  final double convergeTolerance;

  /// 一次校正批最多执行几帧（有界；issue #114 实测 1–2 帧足够）。
  final int defaultBudget;

  FollowIntent _intent = FollowIntent.followLatest;
  bool _dragging = false;
  int _generation = 0;
  int _programmaticDepth = 0;
  bool _frameBooked = false;
  bool _disposed = false;
  _PendingCorrection? _pending;
  ScrollGeometry? _lastGeometry;

  bool _nearBottom = true;
  bool _showJumpToLatest = false;

  int _jumpCount = 0;
  int _attemptCount = 0;
  int _exhaustedCount = 0;
  int _cancelledByUserCount = 0;
  int _cancelledByIntentCount = 0;
  int _staleGenerationCount = 0;
  int _programmaticDragInterrupts = 0;

  // ── 只读状态（生产/测试共用） ──────────────────────────────────────
  FollowIntent get intent => _intent;
  bool get isFollowing => _intent == FollowIntent.followLatest;
  bool get isDragging => _dragging;
  bool get isProgrammaticScroll => _programmaticDepth > 0;
  int get generation => _generation;

  /// 派生展示：几何上是否接近底部（160px 产品阈值）；不参与意图判定。
  bool get nearBottom => _nearBottom;

  /// 派生展示：是否显示「回到底部」按钮/刻度轨。
  bool get showJumpToLatest => _showJumpToLatest;

  bool get hasPendingCorrection => _pending != null;
  ScrollGeometry? get lastGeometry => _lastGeometry;

  /// 诊断计数（§6.2「校正次数」）。
  int get jumpCount => _jumpCount;
  int get attemptCount => _attemptCount;
  int get exhaustedCount => _exhaustedCount;
  int get cancelledByUserCount => _cancelledByUserCount;
  int get cancelledByIntentCount => _cancelledByIntentCount;
  int get staleGenerationCount => _staleGenerationCount;
  int get programmaticDragInterrupts => _programmaticDragInterrupts;

  // ── 用户动作 ───────────────────────────────────────────────────────
  /// 真实用户拖拽开始（只允许由带 dragDetails 的 ScrollStart/Update 调用）。
  /// 立即让已排队校正失效（§5.1）；整个手势（含松手后的惯性）期间不再执行校正。
  void onUserScrollStart(ScrollGeometry geometry) {
    _dragging = true;
    _updateDisplay(geometry);
    _cancelPending(userGesture: true);
  }

  void onUserScrollUpdate(ScrollGeometry geometry) {
    _dragging = true;
    _updateDisplay(geometry);
    _cancelPending(userGesture: true);
  }

  /// 真实用户手势结束（滚动活动停止，含惯性结束）。
  ///
  /// 意图恢复只由「用户动作 + 几何判据」决定：**真正到底**（容差内）才恢复跟随；
  /// 其余一律进入阅读（不是 160px 产品阈值——那是按钮显隐用的）。
  /// 滚动生命周期：Flutter 在滚动活动真正结束时才派发 ScrollEnd，其几何即停稳后的
  /// 几何；惯性（ballistic）结束后没有第二个 ScrollEnd，所以这里必须按最终几何判定。
  /// 内容/布局变化本身不改变意图（§5.2）。
  void onUserScrollEnd(ScrollGeometry geometry) {
    _dragging = false;
    _updateDisplay(geometry);
    _intent = _isAtBottom(geometry)
        ? FollowIntent.followLatest
        : FollowIntent.reading;
    _refreshShowJumpToLatest();
  }

  /// 非用户驱动的几何变化（滚动 tick / ScrollMetricsNotification）。
  ///
  /// 只更新派生展示；**不**改意图。意图只由真实用户手势（拖拽/惯性结束）、显式
  /// 导航/回底/强制定位改变——不能从 pixels 移动方向逆推（§5.2：几何不得反写意图；
  /// 键盘/视口/框架布局调整同样会移动 pixels，programmaticDepth 也覆盖不全）。
  void onMetrics(ScrollGeometry geometry) {
    _updateDisplay(geometry);
  }

  // ── 世代 / 模式 ───────────────────────────────────────────────────
  /// 会话切换：世代前进、意图复位跟随。
  ///
  /// 待执行校正**不在这里直接丢弃**：保留下一个帧去执行时由 [takeCorrection] 的
  /// 世代检查丢弃并计入 `staleGenerationCount`——这样这条守卫是真正可达、可测的
  /// （否则“先取消 pending”会让它永远走不到）。
  void onSessionChanged() {
    _generation += 1;
    _intent = FollowIntent.followLatest;
    _dragging = false;
    _refreshShowJumpToLatest();
  }

  /// 显式轮次定位/历史导航开始：暂停自动跟随；旧世代校正由执行时守卫丢弃。
  void onNavigationStarted() {
    _generation += 1;
    _intent = FollowIntent.reading;
    _refreshShowJumpToLatest();
  }

  /// 历史/实时视图切换等「重新定位」场景：世代前进；旧世代校正由执行时守卫丢弃。
  void bumpGeneration({FollowIntent? intent}) {
    _generation += 1;
    if (intent != null) _intent = intent;
    _dragging = false;
    _refreshShowJumpToLatest();
  }

  // ── 请求 ───────────────────────────────────────────────────────────
  /// 内容/布局版本变化后的跟随请求。
  ///
  /// 阅读态、拖拽中一律不排队（用户/阅读意图优先）；跟随态则合并进同一批待执行校正。
  void requestFollowOnLayout([ScrollGeometry? geometry]) {
    if (_disposed) return;
    if (geometry != null) _updateDisplay(geometry);
    if (_dragging) return;
    if (_intent != FollowIntent.followLatest) return;
    _book(CorrectionReason.contentLayout, defaultBudget);
  }

  /// 强制定位（初始打开/回 live/发送/点击回底）：显式进入跟随并请求有界收敛。
  void requestForcedFollow({
    CorrectionReason reason = CorrectionReason.forcedPosition,
    int? budget,
    ScrollGeometry? geometry,
  }) {
    if (_disposed) return;
    _intent = FollowIntent.followLatest;
    if (geometry != null) {
      _updateDisplay(geometry);
    } else {
      _refreshShowJumpToLatest();
    }
    _book(reason, budget ?? defaultBudget);
  }

  /// issue #123：布局变短后的**越界夹回**请求（`pixels` 落到 `[minExtent, maxExtent]` 外）。
  ///
  /// 与跟随校正共用同一决策 seam 与守卫，但语义不是「跟随最新」而是**机械修正**：
  /// - 目标 = 当前 `pixels` 夹回合法区间后的位置，**永远不是 `maxExtent`**；
  /// - 因此阅读态不阻止：合法阅读位置（含 center 之前的负区间）根本不会发起请求，
  ///   真越界时夹回也不改变用户在看哪段内容；若这里也按阅读态拒绝，越界位置会
  ///   一直留着（#118 的「内容被推到视口上方」正是这样产生的）；
  /// - 拖拽中一律作废（用户手势优先），世代失效由 [takeCorrection] 复核后作废。
  ///
  /// 为什么不能直接 `jumpTo`：`#123` P1 的原始实现只看 `max` 就 `jumpTo(0)`，
  /// 把 center 布局的合法负区间当成越界——用户正在读的历史被抢回 center。
  void requestRangeClamp({ScrollGeometry? geometry, int budget = 2}) {
    if (_disposed) return;
    if (geometry != null) _updateDisplay(geometry);
    if (_dragging) return;
    if (geometry != null && geometry.rangeError <= convergeTolerance) return;
    _book(CorrectionReason.rangeClamp, budget);
  }

  void _book(CorrectionReason reason, int budget) {
    final current = _pending;
    if (current == null) {
      _pending = _PendingCorrection(
        reason: reason,
        budget: budget < 1 ? 1 : budget,
        generation: _generation,
      );
    } else {
      // 合并：保留更显式的原因、较大的预算和已消耗的尝试次数。
      if (_reasonRank(reason) > _reasonRank(current.reason)) {
        current.reason = reason;
      }
      if (budget > current.budget) current.budget = budget;
      if (current.generation != _generation) {
        current.generation = _generation;
        current.attempt = 0;
      }
    }
    _ensureFrameBooked();
  }

  void _ensureFrameBooked() {
    if (_disposed || _frameBooked || _pending == null) return;
    _frameBooked = true;
    ensureFrame();
  }

  // ── 执行（适配器在帧后调用） ───────────────────────────────────────
  /// 取一次可执行的校正。
  ///
  /// 返回 null 表示本帧不动作：无待执行、拖拽中（用户优先）、阅读态（跟随校正）、
  /// 世代失效、或已收敛。执行时逐项重查，防止「安排时有效、执行时已失效」。
  ///
  /// issue #123：`rangeClamp` 的目标是「当前 pixels 夹回合法区间」而不是末端，
  /// 它不改变用户在看哪段内容，所以不受阅读态拦截（合法阅读位置不会被请求）；
  /// 真越界时必须夹回，否则位置会一直留在 `[min, max]` 之外。
  ScrollCorrection? takeCorrection(ScrollGeometry geometry) {
    _updateDisplay(geometry);
    _frameBooked = false;
    final pending = _pending;
    if (_disposed || pending == null) return null;
    if (pending.generation != _generation) {
      _staleGenerationCount += 1;
      _pending = null;
      return null;
    }
    if (_dragging) {
      // 用户手势优先：排队中的校正直接作废（§5.1）。
      _cancelledByUserCount += 1;
      _pending = null;
      return null;
    }
    final rangeClamp = pending.reason == CorrectionReason.rangeClamp;
    if (!rangeClamp && _intent != FollowIntent.followLatest) {
      _cancelledByIntentCount += 1;
      _pending = null;
      return null;
    }
    if (rangeClamp) {
      if (geometry.rangeError <= convergeTolerance) {
        _pending = null; // 已回到合法区间：无需动作
        return null;
      }
      return ScrollCorrection(
        targetPixels: geometry.pixels.clamp(
          geometry.minExtent,
          geometry.maxExtent,
        ),
        reason: pending.reason,
        attempt: pending.attempt,
        budget: pending.budget,
        generation: pending.generation,
      );
    }
    if (_isConverged(geometry)) {
      _pending = null;
      return null;
    }
    return ScrollCorrection(
      targetPixels: geometry.maxExtent,
      reason: pending.reason,
      attempt: pending.attempt,
      budget: pending.budget,
      generation: pending.generation,
    );
  }

  /// 适配器执行完一次 `jumpTo(decision.targetPixels)` 后回报。
  ///
  /// 预算内会再排一帧做「布局后复核」；预算耗尽则停止（exhausted 计数用于诊断）。
  void noteCorrectionApplied(ScrollCorrection decision) {
    _jumpCount += 1;
    _attemptCount += 1;
    final pending = _pending;
    if (pending == null || pending.generation != _generation) {
      _pending = null;
      return;
    }
    pending.attempt += 1;
    if (pending.attempt >= pending.budget) {
      _pending = null;
      _exhaustedCount += 1;
      return;
    }
    _ensureFrameBooked();
  }

  /// 适配器无法执行（无 clients / 视图已切走）时丢弃待执行校正。
  void cancelPending() => _cancelPending();

  // ── 程序性滚动标记 ─────────────────────────────────────────────────
  /// 程序性滚动期间，所有 ScrollEnd 都不得被当作「用户手势结束」。
  ///
  /// 同时：程序性滚动会取消正在进行的 DragScrollActivity（框架行为），所以拖拽
  /// 状态必须一起失效，否则会出现“僵尸拖拽”（flag=true 但物理手势已被取消）。
  void beginProgrammaticScroll() {
    _programmaticDepth += 1;
    if (_dragging) {
      _dragging = false;
      _programmaticDragInterrupts += 1;
    }
  }

  void endProgrammaticScroll() {
    if (_programmaticDepth > 0) _programmaticDepth -= 1;
  }

  /// 页面销毁：丢弃待执行、拒绝后续请求（避免释放后 setState/滚动）。
  void dispose() {
    _disposed = true;
    _pending = null;
    _frameBooked = false;
  }

  // ── 内部 ───────────────────────────────────────────────────────────
  void _cancelPending({bool userGesture = false}) {
    if (_pending == null) return;
    _pending = null;
    _frameBooked = false;
    if (userGesture) _cancelledByUserCount += 1;
  }

  /// 意图判据：**真正到底**（容差内；越过末端也算到底）。不看 160px 产品阈值。
  bool _isAtBottom(ScrollGeometry geometry) =>
      geometry.distanceToEnd <= convergeTolerance;

  /// 展示判据：产品阈值（接近底部），只影响回底按钮/刻度轨。
  bool _isNearBottom(ScrollGeometry geometry) =>
      geometry.distanceToEnd <= nearBottomThreshold;

  bool _isConverged(ScrollGeometry geometry) =>
      geometry.distanceToEnd.abs() <= convergeTolerance &&
      geometry.rangeError <= convergeTolerance;

  void _updateDisplay(ScrollGeometry geometry) {
    _lastGeometry = geometry;
    _nearBottom = _isNearBottom(geometry);
    _refreshShowJumpToLatest();
  }

  /// 回底按钮/刻度轨显隐 = 派生展示。
  ///
  /// 维护者决策（#114 P2）：**阅读态始终显示回底入口**——用户上翻即取消钉底，
  /// 必须始终能看到一个明确的“回到底部”；160px 产品阈值只用于跟随态（近底隐藏）。
  /// 这消除了“reading + 距底 130px → 按钮隐藏但又不跟随”的死角。
  void _refreshShowJumpToLatest() {
    final show = _intent == FollowIntent.reading || !_nearBottom;
    if (show != _showJumpToLatest) _showJumpToLatest = show;
  }
}
