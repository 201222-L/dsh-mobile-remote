// issue #114 §6.3 第 1 层：滚动跟随 owner 的策略/调度单测。
//
// 这一层不依赖 Flutter 渲染：所有几何都是构造出来的 ScrollGeometry，
// 帧调度用 [ensureFrame] 计数模拟。覆盖意图转换（真正到底才钉底）、
// 派生展示（160px 只用于按钮显隐）、取消/世代、合并、预算耗尽、
// 执行时拖拽守卫与程序性滚动生命周期。

import 'package:dsh_mobile_app/scroll_follow.dart';
import 'package:flutter_test/flutter_test.dart';

ScrollGeometry _geo({
  required double pixels,
  required double max,
  double min = 0,
  double viewport = 600,
}) => ScrollGeometry(
  pixels: pixels,
  minExtent: min,
  maxExtent: max,
  viewportDimension: viewport,
);

class _Harness {
  _Harness({int budget = 4}) {
    coordinator = ScrollFollowCoordinator(
      ensureFrame: () => ensureFrameCalls += 1,
      defaultBudget: budget,
    );
  }

  late final ScrollFollowCoordinator coordinator;
  int ensureFrameCalls = 0;

  /// 只取决策、不模拟执行（用于验证执行时守卫）。
  ScrollCorrection? decision(ScrollGeometry geometry) =>
      coordinator.takeCorrection(geometry);

  /// 模拟一帧：帧后取校正；有决策则执行并回报。
  ScrollCorrection? frame(ScrollGeometry geometry) {
    final decision = coordinator.takeCorrection(geometry);
    if (decision != null) coordinator.noteCorrectionApplied(decision);
    return decision;
  }
}

void main() {
  group('意图转换：真正到底才钉底', () {
    test('初始为跟随；内容/几何变化只改派生展示，不改意图', () {
      final h = _Harness();
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(h.coordinator.showJumpToLatest, isFalse);

      h.coordinator.onMetrics(_geo(pixels: 100, max: 1000));
      expect(
        h.coordinator.intent,
        FollowIntent.followLatest,
        reason: '仅几何变化不得把意图改成阅读',
      );
      expect(
        h.coordinator.showJumpToLatest,
        isTrue,
        reason: '离底部超过阈值 → 展示回底按钮',
      );
      expect(h.coordinator.nearBottom, isFalse);

      h.coordinator.onMetrics(_geo(pixels: 980, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(h.coordinator.showJumpToLatest, isFalse);
      expect(h.coordinator.nearBottom, isTrue);
    });

    test('用户拖拽结束：只有真正到底才恢复跟随（160px 不参与意图判定）', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 1000, max: 1000));
      expect(h.coordinator.isDragging, isTrue);
      h.coordinator.onUserScrollEnd(_geo(pixels: 900, max: 1000));
      expect(
        h.coordinator.intent,
        FollowIntent.reading,
        reason: '距底 100px（在 160 展示阈值内）但未真正到底 → 阅读',
      );
      expect(h.coordinator.isDragging, isFalse);

      h.coordinator.onUserScrollStart(_geo(pixels: 900, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 1000, max: 1000));
      expect(
        h.coordinator.intent,
        FollowIntent.followLatest,
        reason: '真正到底（0px）→ 恢复跟随',
      );

      h.coordinator.onUserScrollStart(_geo(pixels: 1000, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 999.5, max: 1000));
      expect(
        h.coordinator.intent,
        FollowIntent.followLatest,
        reason: '容差内（0.5px）也算真正到底',
      );

      h.coordinator.onUserScrollStart(_geo(pixels: 999.5, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 998, max: 1000));
      expect(
        h.coordinator.intent,
        FollowIntent.reading,
        reason: '超出容差（2px）→ 不钉底',
      );
    });

    test('越过末端（overscroll/回弹）算到底', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 1005, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 1005, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
    });

    test('显式回底/强制定位：直接进入跟随', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 200, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 200, max: 1000));
      expect(h.coordinator.intent, FollowIntent.reading);

      h.coordinator.requestForcedFollow(
        reason: CorrectionReason.explicitBackToBottom,
        geometry: _geo(pixels: 200, max: 1000),
      );
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(h.coordinator.hasPendingCorrection, isTrue);
    });

    test('显式轮次导航：进入阅读；旧世代校正在执行时被丢弃（守卫可达）', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      expect(h.coordinator.hasPendingCorrection, isTrue);
      h.coordinator.onNavigationStarted();
      expect(h.coordinator.intent, FollowIntent.reading);
      expect(h.coordinator.generation, 1);
      final decision = h.frame(_geo(pixels: 990, max: 1000));
      expect(decision, isNull);
      expect(h.coordinator.jumpCount, 0);
      expect(h.coordinator.staleGenerationCount, 1, reason: '世代检查必须在执行时真正走到');
      expect(h.coordinator.hasPendingCorrection, isFalse);
    });
  });

  group('派生展示（按钮显隐）', () {
    test('阅读态始终显示回底入口（含距底 100px 的原死角）', () {
      final h = _Harness();
      // 距底 100px：超过“真正到底”容差，但仍在 160px 展示阈值内。
      h.coordinator.onUserScrollStart(_geo(pixels: 900, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 900, max: 1000));
      expect(h.coordinator.intent, FollowIntent.reading);
      expect(
        h.coordinator.nearBottom,
        isTrue,
        reason: '160px 展示阈值仍然生效（几何上的 near）',
      );
      expect(
        h.coordinator.showJumpToLatest,
        isTrue,
        reason: '阅读态必须始终看到回底入口，不能出现“不跟随又没入口”的死角',
      );

      // 距底 10px（仍在 160 内）→ 阅读态也必须显示。
      h.coordinator.onUserScrollStart(_geo(pixels: 990, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 990, max: 1000));
      expect(h.coordinator.intent, FollowIntent.reading);
      expect(
        h.coordinator.showJumpToLatest,
        isTrue,
        reason: '距底 10px 未真正到底 → 阅读态，同样必须有入口',
      );
    });

    test('跟随态 + 距底 200px（非末端）：按新规则显示回底入口', () {
      final h = _Harness();
      expect(h.coordinator.intent, FollowIntent.followLatest);
      h.coordinator.onMetrics(_geo(pixels: 800, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(
        h.coordinator.showJumpToLatest,
        isTrue,
        reason: '跟随态但不在末端：仍给出回底入口',
      );
    });

    test('跟随态按 160px 产品阈值隐藏按钮；纯几何/向末端移动不改意图', () {
      final h = _Harness();
      h.coordinator.onMetrics(_geo(pixels: 900, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(
        h.coordinator.showJumpToLatest,
        isFalse,
        reason: '跟随态 + 距底 100px（160 内）→ 隐藏',
      );
      // 向末端移动（pixels 增大）或只改 max：不得改意图。
      h.coordinator.onMetrics(_geo(pixels: 980, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      h.coordinator.onMetrics(_geo(pixels: 980, max: 1400));
      expect(
        h.coordinator.intent,
        FollowIntent.followLatest,
        reason: '内容增高只改 max，不改意图（§5.2）',
      );
      expect(h.coordinator.showJumpToLatest, isTrue);
    });

    test('onMetrics 不因 pixels 移动方向改意图（意图只由用户手势/显式动作改变）', () {
      final h = _Harness();
      h.coordinator.onMetrics(_geo(pixels: 1000, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      h.coordinator.onMetrics(_geo(pixels: 500, max: 1000));
      expect(
        h.coordinator.intent,
        FollowIntent.followLatest,
        reason: '像素向顶部移动不是意图信号（§5.2：几何不得反写意图）',
      );
      h.coordinator.onMetrics(_geo(pixels: 900, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
    });
  });

  group('会话 / 模式', () {
    test('会话切换：世代前进、意图复位跟随、拖拽清空；旧校正执行时丢弃', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 200, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 200, max: 1000));
      h.coordinator.requestForcedFollow(geometry: _geo(pixels: 200, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      final before = h.coordinator.generation;
      h.coordinator.onSessionChanged();
      expect(h.coordinator.generation, before + 1);
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(h.coordinator.isDragging, isFalse);
      expect(
        h.coordinator.hasPendingCorrection,
        isTrue,
        reason: 'pending 保留到执行时由世代守卫丢弃（不提前取消，保证守卫可达）',
      );
      expect(h.frame(_geo(pixels: 200, max: 1000)), isNull);
      expect(h.coordinator.jumpCount, 0);
      expect(h.coordinator.staleGenerationCount, 1);
      expect(h.coordinator.hasPendingCorrection, isFalse);
    });

    test('bumpGeneration 不带意图时保留当前意图', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 200, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 200, max: 1000));
      expect(h.coordinator.intent, FollowIntent.reading);
      h.coordinator.bumpGeneration();
      expect(h.coordinator.intent, FollowIntent.reading);
    });
  });

  group('程序性滚动生命周期', () {
    test('begin/endProgrammaticScroll 标记可嵌套且成对归零', () {
      final h = _Harness();
      expect(h.coordinator.isProgrammaticScroll, isFalse);
      h.coordinator.beginProgrammaticScroll();
      h.coordinator.beginProgrammaticScroll();
      expect(h.coordinator.isProgrammaticScroll, isTrue);
      h.coordinator.endProgrammaticScroll();
      expect(h.coordinator.isProgrammaticScroll, isTrue);
      h.coordinator.endProgrammaticScroll();
      expect(h.coordinator.isProgrammaticScroll, isFalse);
    });

    test('程序性滚动会中断用户拖拽状态（框架会取消 DragScrollActivity）', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 400, max: 1000));
      expect(h.coordinator.isDragging, isTrue);
      h.coordinator.beginProgrammaticScroll();
      expect(h.coordinator.isDragging, isFalse, reason: '不得留下“僵尸拖拽”');
      expect(h.coordinator.programmaticDragInterrupts, 1);
      h.coordinator.endProgrammaticScroll();
      expect(h.coordinator.isProgrammaticScroll, isFalse);
    });
  });

  group('帧调度', () {
    test('请求即要求一帧；收敛后不再排帧（无空闲自激）', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      expect(h.ensureFrameCalls, 1, reason: '有待执行校正必须自己保证有帧');

      final first = h.frame(_geo(pixels: 990, max: 1000));
      expect(first, isNotNull);
      expect(h.ensureFrameCalls, 2, reason: '预算内排下一帧做布局后复核');

      final second = h.frame(_geo(pixels: 1000, max: 1000));
      expect(second, isNull, reason: '已收敛不动作');
      expect(h.ensureFrameCalls, 2, reason: '收敛后不得再排帧');
      expect(h.coordinator.hasPendingCorrection, isFalse);
    });

    test('合并：同一批多次请求只排一帧，原因取更显式者', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      h.coordinator.requestFollowOnLayout(_geo(pixels: 980, max: 1000));
      h.coordinator.requestForcedFollow(
        reason: CorrectionReason.explicitBackToBottom,
        geometry: _geo(pixels: 980, max: 1000),
      );
      expect(h.ensureFrameCalls, 1);
      final decision = h.frame(_geo(pixels: 980, max: 1000));
      expect(decision!.reason, CorrectionReason.explicitBackToBottom);
    });

    test('强制定位与内容跟随合并时取更显式原因与较大预算', () {
      final h = _Harness(budget: 4);
      h.coordinator.requestForcedFollow(
        reason: CorrectionReason.forcedPosition,
        budget: 2,
        geometry: _geo(pixels: 0, max: 1000),
      );
      h.coordinator.requestFollowOnLayout(_geo(pixels: 10, max: 1000));
      final decision = h.frame(_geo(pixels: 10, max: 1000));
      expect(decision!.reason, CorrectionReason.forcedPosition);
      expect(decision.budget, 4);
    });

    test('预算耗尽：几何始终不收敛时按预算停止并计数', () {
      final h = _Harness(budget: 3);
      h.coordinator.requestFollowOnLayout(_geo(pixels: 0, max: 1000));
      var attempts = 0;
      // 每帧 max 都继续变大，模拟 lazy 估值持续修正（永不收敛）。
      for (var i = 0; i < 10; i++) {
        final decision = h.frame(_geo(pixels: 0, max: 1000 + i * 100));
        if (decision != null) attempts += 1;
      }
      expect(attempts, 3, reason: '有界：最多 defaultBudget 次 jump');
      expect(h.coordinator.exhaustedCount, 1);
      expect(h.coordinator.hasPendingCorrection, isFalse);
      expect(h.ensureFrameCalls, 3, reason: '预算耗尽后不再排帧');
    });
  });

  group('取消与世代', () {
    test('用户拖拽开始立即作废已排队校正', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      expect(h.coordinator.hasPendingCorrection, isTrue);
      h.coordinator.onUserScrollStart(_geo(pixels: 990, max: 1000));
      expect(h.coordinator.hasPendingCorrection, isFalse);
      expect(h.coordinator.cancelledByUserCount, 1);
    });

    test('拖拽中不排队；执行时再查拖拽（双重守卫）', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 900, max: 1000));
      h.coordinator.requestFollowOnLayout(_geo(pixels: 900, max: 1000));
      expect(h.coordinator.hasPendingCorrection, isFalse, reason: '拖拽中不排队');
      expect(h.ensureFrameCalls, 0);
    });

    test('安排时有效、执行前开始拖拽 → 执行时取消', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      // 帧还没跑，用户先开始拖拽。
      h.coordinator.onUserScrollStart(_geo(pixels: 990, max: 1000));
      final decision = h.frame(_geo(pixels: 900, max: 1000));
      expect(decision, isNull);
      expect(h.coordinator.jumpCount, 0);
    });

    test('拖拽中排队的强制定位：执行时被用户手势守卫拦下（守卫可达）', () {
      final h = _Harness();
      // 先进入拖拽，再在拖拽中排一个强制定位——requestForcedFollow 允许排队，
      // 真正的拦截必须发生在执行时的 takeCorrection（而不是安排时被提前取消）。
      h.coordinator.onUserScrollStart(_geo(pixels: 200, max: 1000));
      h.coordinator.requestForcedFollow(
        reason: CorrectionReason.explicitBackToBottom,
        geometry: _geo(pixels: 200, max: 1000),
      );
      expect(h.coordinator.hasPendingCorrection, isTrue);
      final decision = h.decision(_geo(pixels: 200, max: 1000));
      expect(decision, isNull, reason: '拖拽中不得执行任何校正');
      expect(h.coordinator.jumpCount, 0);
      expect(h.coordinator.cancelledByUserCount, 1);
      expect(
        h.coordinator.intent,
        FollowIntent.followLatest,
        reason: '显式回底的意图保留，但不得在拖拽中执行',
      );
    });

    test('世代失效的校正不得执行（执行时守卫可达）', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      h.coordinator.bumpGeneration(intent: FollowIntent.followLatest);
      final decision = h.frame(_geo(pixels: 990, max: 1000));
      expect(decision, isNull);
      expect(
        h.coordinator.staleGenerationCount,
        1,
        reason: '旧世代 pending 保留到执行时被丢弃',
      );
      expect(h.coordinator.hasPendingCorrection, isFalse);
      expect(h.coordinator.jumpCount, 0);
    });

    test('阅读态不自动排队，但强制定位可以覆盖', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 300, max: 1000));
      h.coordinator.onUserScrollEnd(_geo(pixels: 300, max: 1000));
      expect(h.coordinator.intent, FollowIntent.reading);

      h.coordinator.requestFollowOnLayout(_geo(pixels: 300, max: 1000));
      expect(
        h.coordinator.hasPendingCorrection,
        isFalse,
        reason: '阅读态不得被布局变化抢回',
      );
      expect(h.ensureFrameCalls, 0);

      h.coordinator.requestForcedFollow(geometry: _geo(pixels: 300, max: 1000));
      expect(h.coordinator.intent, FollowIntent.followLatest);
      expect(h.ensureFrameCalls, 1);
    });

    test('dispose 后不再排帧、不再执行', () {
      final h = _Harness();
      h.coordinator.dispose();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 990, max: 1000));
      h.coordinator.requestForcedFollow(geometry: _geo(pixels: 0, max: 1000));
      expect(h.ensureFrameCalls, 0);
      expect(h.frame(_geo(pixels: 0, max: 1000)), isNull);
    });
  });

  group('几何判据', () {
    test('越界（pixels > max）不算收敛，校正目标为 max', () {
      final h = _Harness();
      h.coordinator.requestForcedFollow(
        geometry: _geo(pixels: 2000, max: 1000),
      );
      final decision = h.frame(_geo(pixels: 2000, max: 1000));
      expect(decision, isNotNull);
      expect(decision!.targetPixels, 1000);
      expect(_geo(pixels: 2000, max: 1000).rangeError, 1000);
    });

    test('center 负 min 的越界按实际 min 计算，不夹成 0', () {
      final g = _geo(pixels: -20, max: 1000, min: -10);
      expect(g.rangeError, 10);
    });

    test('rangeClamp：center 负区间内的负 pixels 是合法位置，不发起也不误夹', () {
      final h = _Harness();
      // #123 P1 现场几何：min=-1518, max=0, pixels=-990（上翻加载过更早历史）。
      final pagedReading = _geo(pixels: -990, max: 0, min: -1518);
      h.coordinator.onUserScrollStart(pagedReading);
      h.coordinator.onUserScrollEnd(pagedReading);
      expect(h.coordinator.intent, FollowIntent.reading);
      h.coordinator.requestRangeClamp(geometry: pagedReading);
      expect(
        h.coordinator.hasPendingCorrection,
        isFalse,
        reason: '合法历史阅读位置（rangeError=0）不得排任何校正',
      );
      expect(h.frame(pagedReading), isNull);
      expect(h.coordinator.jumpCount, 0);
    });

    test('rangeClamp：真越界时目标是最接近当前 pixels 的合法位置（不是末端）', () {
      final h = _Harness();
      // 内容变短：max 从 1000 掉到 0，pixels 仍停在 400（> max）→ 应夹回 0。
      final shrunk = _geo(pixels: 400, max: 0);
      h.coordinator.requestRangeClamp(geometry: shrunk);
      final decision = h.frame(shrunk);
      expect(decision, isNotNull);
      expect(decision!.reason, CorrectionReason.rangeClamp);
      expect(decision.targetPixels, 0);
      // 另一个方向：pixels < min（center 之前的历史被裁掉）→ 夹回 min。
      final h2 = _Harness();
      final shrunkBelow = _geo(pixels: -900, max: 0, min: -300);
      h2.coordinator.requestRangeClamp(geometry: shrunkBelow);
      final below = h2.frame(shrunkBelow);
      expect(below, isNotNull);
      expect(below!.targetPixels, -300);
    });

    test('rangeClamp：阅读态也允许（合法位置不会发起；越界必须夹回，否则位置一直非法）', () {
      final h = _Harness();
      h.coordinator.onUserScrollEnd(_geo(pixels: 100, max: 1000));
      expect(h.coordinator.intent, FollowIntent.reading);
      final g = _geo(pixels: 400, max: 0);
      h.coordinator.requestRangeClamp(geometry: g);
      final decision = h.frame(g);
      expect(decision, isNotNull, reason: '真越界时阅读态不得阻止夹回');
      expect(decision!.targetPixels, 0);
    });

    test('rangeClamp：拖拽中作废（用户手势优先）', () {
      final h = _Harness();
      h.coordinator.onUserScrollStart(_geo(pixels: 400, max: 0));
      h.coordinator.requestRangeClamp(geometry: _geo(pixels: 400, max: 0));
      expect(h.coordinator.hasPendingCorrection, isFalse,
          reason: '拖拽中不排队');
      // 安排时未拖拽、执行前开始拖拽：执行时守卫仍要拦下。
      final h2 = _Harness();
      h2.coordinator.requestRangeClamp(geometry: _geo(pixels: 400, max: 0));
      h2.coordinator.onUserScrollStart(_geo(pixels: 400, max: 0));
      expect(h2.frame(_geo(pixels: 400, max: 0)), isNull);
      expect(h2.coordinator.cancelledByUserCount, greaterThan(0));
    });

    test('rangeClamp：世代失效作废', () {
      final h = _Harness();
      h.coordinator.requestRangeClamp(geometry: _geo(pixels: 400, max: 0));
      h.coordinator.bumpGeneration();
      expect(h.frame(_geo(pixels: 400, max: 0)), isNull);
      expect(h.coordinator.staleGenerationCount, greaterThan(0));
    });

    test('rangeClamp 与内容跟随合并：跟随态下取更显式的原因（目标=末端）', () {
      final h = _Harness();
      h.coordinator.requestRangeClamp(geometry: _geo(pixels: 400, max: 0));
      h.coordinator.requestFollowOnLayout(_geo(pixels: 400, max: 0));
      final decision = h.frame(_geo(pixels: 400, max: 0));
      expect(decision, isNotNull);
      expect(decision!.reason, CorrectionReason.contentLayout);
      expect(decision.targetPixels, 0);
    });

    test('160px 阈值只决定展示，不决定 1px 收敛容差', () {
      final h = _Harness();
      h.coordinator.requestFollowOnLayout(_geo(pixels: 840, max: 1000));
      final decision = h.frame(_geo(pixels: 840, max: 1000));
      expect(decision, isNotNull, reason: '跟随态下 160px 内仍需收敛到真实末端');
      final converged = h.frame(_geo(pixels: 1000, max: 1000));
      expect(converged, isNull);
    });
  });
}
