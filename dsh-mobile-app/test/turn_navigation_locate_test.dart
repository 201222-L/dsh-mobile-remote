// issue #24：定位机制回归测试（Seam 3）。
//
// 这条风险线是本功能最容易出错的地方：消息流是**懒构建**的 `SliverList` 且带
// `center` 锚点（偏移 0 是中间占位块、上翻后最小滚动范围为负），屏幕外的条目
// 没有渲染对象。
//
// 本文件做三件事：
//   1. 用真实 Flutter 布局把"`ensureVisible` 不足以定位未构建条目"这一**约束**
//      钉死——它是 ADR 0018 实现期修订的直接依据；
//   2. 验证有界迭代定位（`TurnLocator`）在这套真实结构上**能收敛**，且成功判据
//      是"目标与视口相交"（不是"已构建"）；
//   3. 钉死失败原因（notInWindow / exhausted）、绝对时间安全网（kTurnLocateHardCapMs）
//      与基于实测几何的校正（不等高条目也能收敛）。
//
// 与 `chat_scroll_regression_test.dart` 同一条风险线（负偏移、prepend 保位）。

import 'package:dsh_mobile_app/turn_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每条第 10 项是"轮次边界"，挂 GlobalKey——与聊天页给轮次边界挂 key 同构。
const int _kRowHeight = 60;
const int _kRowCount = 200;
const int _kTurnStride = 10;

/// 构造一个带默认回调的定位器；各用例只覆盖自己关心的那几个。
TurnLocator _locator({
  required void Function(double) scrollTo,
  double Function()? minScrollExtent,
  double Function()? maxScrollExtent,
  bool Function()? isTargetLoaded,
  bool Function()? isTargetBuilt,
  bool Function()? isTargetInView,
  Future<void> Function()? reveal,
  List<TurnMeasurement> Function()? measure,
  List<BuiltChildMeasurement> Function()? measureBuilt,
  double Function()? currentOffset,
  double Function()? viewportExtent,
  Future<void> Function()? settle,
  int maxAttempts = kTurnLocateMaxAttempts,
  Duration timeout = const Duration(milliseconds: kTurnLocateHardCapMs),
  DateTime Function()? clock,
}) {
  return TurnLocator(
    scrollTo: scrollTo,
    minScrollExtent: minScrollExtent ?? () => 0,
    maxScrollExtent: maxScrollExtent ?? () => 1000,
    isTargetLoaded: isTargetLoaded ?? () => true,
    isTargetBuilt: isTargetBuilt ?? () => false,
    isTargetInView: isTargetInView ?? () => false,
    reveal: reveal ?? () async {},
    measure: measure ?? () => const [],
    measureBuilt: measureBuilt ?? () => const [],
    currentOffset: currentOffset ?? () => 0,
    viewportExtent: viewportExtent ?? () => 0,
    settle: settle ?? () async {},
    maxAttempts: maxAttempts,
    timeout: timeout,
    clock: clock,
  );
}

void main() {
  group('约束：懒构建下屏幕外的 GlobalKey 不可达', () {
    testWidgets('ensureVisible 无法直接跳到未构建的轮次', (tester) async {
      final turnKeys = <int, GlobalKey>{};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: _kRowCount,
            itemBuilder: (_, i) => SizedBox(
              key: i % _kTurnStride == 0
                  ? turnKeys.putIfAbsent(i ~/ _kTurnStride, () => GlobalKey())
                  : null,
              height: _kRowHeight.toDouble(),
              child: Text('row $i'),
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(turnKeys[0]?.currentContext, isNotNull, reason: '首个边界在视口内');
      expect(turnKeys[15]?.currentContext, isNull,
          reason: '远处边界未构建——这正是 ensureVisible 不足的原因');
    });
  });

  group('TurnLocator：有界迭代定位', () {
    test('目标已在视口内时立即成功，不做任何滚动', () async {
      var scrolls = 0;
      final locator = _locator(
        scrollTo: (_) => scrolls++,
        isTargetInView: () => true,
      );
      final outcome =
          await locator.locate(targetTurn: 3, targetIndex: 3, childCount: 10);
      expect(outcome.ok, isTrue);
      expect(scrolls, 0);
    });

    test('目标已构建但不在视口：先精调，精调后可见即成功', () async {
      var reveals = 0;
      var inView = false;
      final locator = _locator(
        scrollTo: (_) {},
        isTargetBuilt: () => true,
        isTargetInView: () => inView,
        reveal: () async {
          reveals++;
          inView = true;
        },
      );
      final outcome =
          await locator.locate(targetTurn: 3, targetIndex: 3, childCount: 10);
      expect(outcome.ok, isTrue);
      expect(reveals, 1);
    });

    test('落点后目标进入视口即收敛，且尝试次数在上限内', () async {
      var built = false;
      var inView = false;
      var attempts = 0;
      final locator = _locator(
        scrollTo: (_) {
          attempts++;
          built = true; // 模拟"跳过去后该处条目被构建"
        },
        isTargetBuilt: () => built,
        isTargetInView: () => inView,
        settle: () async {
          if (built) inView = true;
        },
      );
      final outcome =
          await locator.locate(targetTurn: 5, targetIndex: 5, childCount: 10);
      expect(outcome.ok, isTrue);
      expect(attempts, 1);
    });

    test('始终不可见时，尝试次数有界且如实返回 exhausted', () async {
      var attempts = 0;
      final locator = _locator(
        scrollTo: (_) => attempts++,
        // 病态：目标既不构建也不可见。
      );
      final outcome =
          await locator.locate(targetTurn: 5, targetIndex: 5, childCount: 10);
      expect(outcome.ok, isFalse);
      expect(outcome.failure, TurnLocateFailure.exhausted);
      expect(attempts, kTurnLocateMaxAttempts, reason: '必须有界——不得无限抖动');
    });

    test('目标不在已加载窗口内 → notInWindow，且不做任何滚动', () async {
      var scrolls = 0;
      final locator = _locator(
        scrollTo: (_) => scrolls++,
        isTargetLoaded: () => false,
      );
      final outcome =
          await locator.locate(targetTurn: 9, targetIndex: 9, childCount: 10);
      expect(outcome.ok, isFalse);
      expect(outcome.failure, TurnLocateFailure.notInWindow);
      expect(scrolls, 0);
    });

    test('绝对时间安全网到时后不再产生副作用，返回 exhausted', () async {
      // 上界是**尝试次数**，墙钟只是绝对安全网（kTurnLocateHardCapMs）。这里让每帧
      // 前进 25 秒，跨过安全网：只允许发生第一次落点，随后立即 exhausted。
      var now = DateTime(2026, 1, 1);
      var scrolls = 0;
      final locator = _locator(
        scrollTo: (_) => scrolls++,
        settle: () async => now = now.add(const Duration(seconds: 25)),
        clock: () => now,
      );
      final outcome =
          await locator.locate(targetTurn: 5, targetIndex: 5, childCount: 10);
      expect(outcome.ok, isFalse);
      expect(outcome.failure, TurnLocateFailure.exhausted);
      expect(scrolls, 1, reason: '安全网到时后不得再滚动');
    });

    test('尾部安全网：最后一次等待跨过绝对上限后不得再 reveal', () async {
      // issue #31 三轮复审 P2 回归：loop 内每轮入口都有超时检查，但**最后一次**落点之后的
      // 等待跨过安全网时已经没有下一轮入口——尾部必须自己早退，否则会在"硬截止"之后
      // 仍发起页面的 reveal（ensureVisible 动画/等待）。复审判例：cap=20s，最后一次等待
      // 让时钟走到 24s，实际仍 reveal 了一次。
      final start = DateTime(2026, 1, 1);
      var now = start;
      var built = false;
      var scrolls = 0;
      final revealAtMs = <int>[];
      final locator = _locator(
        scrollTo: (_) => scrolls++,
        maxScrollExtent: () => 1000,
        isTargetBuilt: () => built,
        isTargetInView: () => false,
        reveal: () async => revealAtMs.add(now.difference(start).inMilliseconds),
        settle: () async {
          built = true; // 最后一轮等待之后目标"已构建但不可见"
          now = now.add(const Duration(seconds: 8));
        },
        maxAttempts: 1,
        clock: () => now,
      );

      final outcome =
          await locator.locate(targetTurn: 2, targetIndex: 4, childCount: 10);

      expect(outcome.failure, TurnLocateFailure.exhausted);
      expect(revealAtMs, isEmpty,
          reason: '最后一次等待已跨过绝对安全网，不得再发起 reveal 精调');
      expect(scrolls, 1, reason: '安全网到时后不得再滚动');
    });

    test('落点被夹在可滚动范围内（center 锚点下的负最小偏移）', () async {
      final offsets = <double>[];
      final locator = _locator(
        scrollTo: offsets.add,
        minScrollExtent: () => -300,
        maxScrollExtent: () => 700,
      );
      await locator.locate(targetTurn: 0, targetIndex: 0, childCount: 5);
      expect(offsets.first, -300);
      expect(offsets.every((o) => o >= -300 && o <= 700), isTrue);
    });
  });

  group('estimateTurnOffsetFromMeasurements：按实测几何校正', () {
    test('目标被两个实测点夹逼时线性插值', () {
      final offset = estimateTurnOffsetFromMeasurements(
        targetTurn: 3,
        measurements: const [
          TurnMeasurement(turn: 1, offset: 100),
          TurnMeasurement(turn: 5, offset: 900),
        ],
        targetIndex: 2,
        childCount: 10,
        minScrollExtent: 0,
        maxScrollExtent: 1000,
      );
      expect(offset, 500);
    });

    test('目标在实测点之后时按最近两点割线外推', () {
      final offset = estimateTurnOffsetFromMeasurements(
        targetTurn: 4,
        measurements: const [
          TurnMeasurement(turn: 1, offset: 100),
          TurnMeasurement(turn: 2, offset: 300),
          TurnMeasurement(turn: 3, offset: 500),
        ],
        targetIndex: 3,
        childCount: 10,
        minScrollExtent: 0,
        maxScrollExtent: 1000,
      );
      expect(offset, 700);
    });

    test('目标在实测点之前时反向外推', () {
      final offset = estimateTurnOffsetFromMeasurements(
        targetTurn: 1,
        measurements: const [
          TurnMeasurement(turn: 3, offset: 500),
          TurnMeasurement(turn: 4, offset: 700),
        ],
        targetIndex: 0,
        childCount: 10,
        minScrollExtent: 0,
        maxScrollExtent: 1000,
      );
      expect(offset, 100);
    });

    test('没有实测点时退回比例估算', () {
      final offset = estimateTurnOffsetFromMeasurements(
        targetTurn: 5,
        measurements: const [],
        targetIndex: 4,
        childCount: 5,
        minScrollExtent: 0,
        maxScrollExtent: 1000,
      );
      expect(offset, 1000);
    });
  });

  group('TurnLocator：按已构建子项的索引 / 几何收窄区间（第二轮 P1）', () {
    test('目标被两个已构建子项夹逼时按索引插值（而不是轮次平均步距）', () async {
      var pixels = 0.0;
      final offsets = <double>[];
      final locator = _locator(
        scrollTo: (o) {
          offsets.add(o);
          pixels = o;
        },
        minScrollExtent: () => 0,
        maxScrollExtent: () => 2000,
        viewportExtent: () => 300,
        currentOffset: () => pixels,
        // 目标（子项 5）夹在子项 3（底部 0）与子项 9（顶部 1000）之间。
        measureBuilt: () => const [
          BuiltChildMeasurement(index: 3, offset: -100, height: 100),
          BuiltChildMeasurement(index: 9, offset: 1000),
        ],
        // 目标边界未构建：只靠邻居几何收敛。
        isTargetBuilt: () => false,
        isTargetInView: () => pixels >= 200 && pixels <= 400,
      );
      final outcome =
          await locator.locate(targetTurn: 5, targetIndex: 5, childCount: 20);
      expect(outcome.ok, isTrue);
      expect(offsets.first, closeTo(-100 + 1100 * (2 / 6), 0.01),
          reason: '按索引比例 (5-3)/(9-3) 插值，而不是按轮次号或平均步距外推');
    });

    test('长回复在目标之前：用子项"底部"作下界，落点必须越过回复', () async {
      var pixels = 0.0;
      final offsets = <double>[];
      // 子项 1 是超长回复（0..10,000）；目标子项 4 在 10,500，只有落点接近时才被构建。
      bool targetBuilt() => 10500 < pixels + 400 && 10600 > pixels - 100;
      final locator = _locator(
        scrollTo: (o) {
          offsets.add(o);
          pixels = o;
        },
        minScrollExtent: () => 0,
        maxScrollExtent: () => 11000,
        viewportExtent: () => 600,
        currentOffset: () => pixels,
        measureBuilt: () => [
          const BuiltChildMeasurement(index: 1, offset: 0, height: 10000),
          if (targetBuilt())
            const BuiltChildMeasurement(index: 4, offset: 10500, height: 100),
        ],
        isTargetBuilt: targetBuilt,
        isTargetInView: () => pixels >= 9900 && pixels <= 10500,
      );
      final outcome =
          await locator.locate(targetTurn: 4, targetIndex: 4, childCount: 8);
      expect(outcome.ok, isTrue);
      expect(offsets.first, greaterThanOrEqualTo(10000),
          reason: '只用子项顶部（0）会把落点留在长回复中段；下界应是 0 + 高度');
    });

    test('区间被实测点夹成一点时，重复落点触发向目标方向的降级步进', () async {
      var pixels = 0.0;
      final offsets = <double>[];
      final locator = _locator(
        scrollTo: (o) {
          offsets.add(o);
          pixels = o;
        },
        minScrollExtent: () => -2000,
        maxScrollExtent: () => 2000,
        viewportExtent: () => 600,
        currentOffset: () => pixels,
        // 退化区间：子项 3 的底部 = 0，子项 5 的顶部 = 0，目标却在这两点之上。
        measureBuilt: () => const [
          BuiltChildMeasurement(index: 3, offset: -100, height: 100),
          BuiltChildMeasurement(index: 5, offset: 0),
        ],
        isTargetBuilt: () => false,
        isTargetInView: () => pixels <= -800 && pixels >= -1400,
      );
      final outcome =
          await locator.locate(targetTurn: 4, targetIndex: 4, childCount: 10);
      expect(outcome.ok, isTrue);
      expect(offsets.first, 0);
      expect(offsets.any((o) => o <= -100), isTrue,
          reason: '同一落点重复时必须按视口比例向目标方向步进，而不是原地重复');
    });
  });

  group('TurnLocator 驱动真实懒构建列表（center 锚点，条目不等高）', () {    testWidgets('远处轮次能被实测几何迭代定位带入视口', (tester) async {
      const centerKey = ValueKey<String>('center');
      final viewportKey = GlobalKey();
      final turnKeys = <int, GlobalKey>{};
      final controller = ScrollController();
      // 前半（center 之前）：远→近；后半（center 之后）：近→远，模拟聊天页两条列表。
      const beforeCount = 100;
      const afterCount = 100;
      // 条目高度不等高：把"轮次边界"所在行做成超高行，比例估算必然失准。
      double rowHeight(int global) =>
          global % _kTurnStride == 0 ? _kRowHeight * 3 : _kRowHeight.toDouble();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            key: viewportKey,
            controller: controller,
            center: centerKey,
            slivers: [
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, index) {
                    final global = beforeCount - 1 - index;
                    return SizedBox(
                      key: global % _kTurnStride == 0
                          ? turnKeys.putIfAbsent(global ~/ _kTurnStride, () => GlobalKey())
                          : null,
                      height: rowHeight(global),
                      child: Text('before $global'),
                    );
                  },
                  childCount: beforeCount,
                ),
              ),
              const SliverToBoxAdapter(key: centerKey, child: SizedBox.shrink()),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, index) {
                    final global = beforeCount + index;
                    return SizedBox(
                      key: global % _kTurnStride == 0
                          ? turnKeys.putIfAbsent(global ~/ _kTurnStride, () => GlobalKey())
                          : null,
                      height: rowHeight(global),
                      child: Text('after $index'),
                    );
                  },
                  childCount: afterCount,
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      // 目标：全局第 20 项 → 序号 2，初始一定不可达。
      const targetTurn = 2;
      expect(turnKeys[targetTurn]?.currentContext, isNull,
          reason: '起始位置下目标不应已构建（否则本用例失去意义）');

      final viewport = viewportKey.currentContext!.findRenderObject() as RenderBox;
      List<TurnMeasurement> measure() {
        if (!controller.hasClients) return const [];
        final viewTop = viewport.localToGlobal(Offset.zero).dy;
        final out = <TurnMeasurement>[];
        turnKeys.forEach((turn, key) {
          final box = key.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          out.add(TurnMeasurement(
            turn: turn,
            offset: controller.offset +
                (box.localToGlobal(Offset.zero).dy - viewTop),
          ));
        });
        return out;
      }

      bool inView() {
        final box =
            turnKeys[targetTurn]?.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return false;
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final viewTop = viewport.localToGlobal(Offset.zero).dy;
        final viewBottom = viewTop + viewport.size.height;
        return bottom > viewTop && top < viewBottom;
      }

      final locator = _locator(
        scrollTo: (offset) {
          if (controller.hasClients) controller.jumpTo(offset);
        },
        minScrollExtent: () =>
            controller.hasClients ? controller.position.minScrollExtent : 0,
        maxScrollExtent: () =>
            controller.hasClients ? controller.position.maxScrollExtent : 0,
        isTargetBuilt: () => turnKeys[targetTurn]?.currentContext != null,
        isTargetInView: inView,
        reveal: () async {
          final ctx = turnKeys[targetTurn]?.currentContext;
          if (ctx == null) return;
          // 无动画：测试体直接 await，动画需要 pump 才能完成。
          await Scrollable.ensureVisible(ctx, alignment: 0.1);
        },
        measure: measure,
        settle: () async {
          await tester.pump();
        },
      );

      final outcome = await locator.locate(
        targetTurn: targetTurn,
        targetIndex: targetTurn * _kTurnStride,
        childCount: beforeCount + afterCount,
      );

      expect(outcome.ok, isTrue, reason: '迭代定位应把远处轮次带入视口');
      expect(inView(), isTrue, reason: '成功判据是"与视口相交"，不是"已构建"');
      // 目标真的进入视口（不只是被构建在缓存区）。
      final box =
          turnKeys[targetTurn]!.currentContext!.findRenderObject() as RenderBox;
      final dy = box.localToGlobal(Offset.zero).dy;
      expect(dy, greaterThanOrEqualTo(-box.size.height));
      expect(dy, lessThan(viewport.size.height));
    });
  });

  // issue #31（方案 B）：尺寸缓存给出的"索引 → 偏移"估算应当**优先于盲二分**。
  group('TurnLocator：索引→偏移估算（尺寸缓存）', () {
    test('首个探针直接用估算值，而不是二分中点', () async {
      final probes = <double>[];
      var built = const <BuiltChildMeasurement>[];
      final locator = TurnLocator(
        scrollTo: probes.add,
        minScrollExtent: () => 0,
        maxScrollExtent: () => 100000,
        currentOffset: () => probes.isEmpty ? 100000 : probes.last,
        viewportExtent: () => 600,
        isTargetLoaded: () => true,
        isTargetBuilt: () => false,
        // 估算值 20000 附近即视为进入视口（阅读线内缩 10% 视口高）。
        isTargetInView: () =>
            probes.isNotEmpty && (probes.last - 20000).abs() < 600,
        reveal: () async {},
        measure: () => const [],
        measureBuilt: () => built,
        estimateOffsetForIndex: (index) => index == 40 ? 20000.0 : null,
        settle: () async {
          // 落点之后目标附近变成"已构建"，后续走精确对准。
          built = const [
            BuiltChildMeasurement(index: 40, offset: 20000, height: 100),
          ];
        },
      );

      final outcome = await locator.locate(
        targetTurn: 2,
        targetIndex: 40,
        childCount: 100,
      );

      expect(outcome.ok, isTrue);
      expect(probes.first, 20000.0,
          reason: '估算可用时应一步落到目标附近，而不是先跳到区间中点（50000）');
      expect(probes.length, lessThanOrEqualTo(2), reason: '查表式估算让长跳 1–2 步收敛');
    });

    test('估算落在搜索区间之外时被拒绝（退回实测区间）', () async {
      final probes = <double>[];
      // 一个实测子项把下界抬到 60000；估算值 1000 低于下界 → 已被证伪，不得采用。
      var built = const [
        BuiltChildMeasurement(index: 10, offset: 60000, height: 100),
      ];
      final locator = TurnLocator(
        scrollTo: probes.add,
        minScrollExtent: () => 0,
        maxScrollExtent: () => 100000,
        currentOffset: () => probes.isEmpty ? 100000 : probes.last,
        viewportExtent: () => 600,
        isTargetLoaded: () => true,
        isTargetBuilt: () => false,
        isTargetInView: () => probes.isNotEmpty && probes.last >= 99000,
        reveal: () async {},
        measure: () => const [],
        measureBuilt: () => built,
        estimateOffsetForIndex: (index) => 1000.0,
        settle: () async {
          built = const [
            BuiltChildMeasurement(index: 10, offset: 60000, height: 100),
            BuiltChildMeasurement(index: 90, offset: 99000, height: 100),
          ];
        },
      );

      await locator.locate(targetTurn: 8, targetIndex: 80, childCount: 100);

      expect(probes.contains(1000.0), isFalse,
          reason: '估算值低于实测下界 60000，已被证伪，不得采用');
      expect(probes.every((p) => p >= 60000), isTrue,
          reason: '落点必须尊重实测区间下界');
    });
  });

  // issue #31 复审 P2/P3：把尺寸缓存的前缀算法抽成纯 seam 直接验证——生产用的是
  // **有符号**的 center 相对坐标，而不是"从最早条目起累加的非负前缀"。
  group('estimateSignedContentOffset：center 相对的有符号前缀', () {
    test('复审给的核对例：older 一条 100 高 → live 首条 0、older 首条 -100', () {
      final heights = <int, double>{0: 100};
      double? heightOf(int index) => heights[index];
      expect(
        estimateSignedContentOffset(
          targetIndex: 1,
          centerIndex: 1,
          childCount: 2,
          cachedHeight: heightOf,
          averageHeight: 50,
        ),
        0,
        reason: 'live 首条就在 center 处，偏移必须是 0',
      );
      expect(
        estimateSignedContentOffset(
          targetIndex: 0,
          centerIndex: 1,
          childCount: 2,
          cachedHeight: heightOf,
          averageHeight: 50,
        ),
        -100,
        reason: 'older 首条在 center 之前，偏移必须是负的',
      );
    });

    test('缓存完整时等于实测前缀差（live 侧为正）', () {
      final heights = <int, double>{0: 100, 1: 50, 2: 200, 3: 60, 4: 70};
      double? heightOf(int index) => heights[index];
      double? at(int target) => estimateSignedContentOffset(
            targetIndex: target,
            centerIndex: 2,
            childCount: 5,
            cachedHeight: heightOf,
            averageHeight: 10,
          );
      expect(at(2), 0);
      expect(at(0), -150);
      expect(at(1), -50);
      expect(at(4), 260);
    });

    test('空缓存退化为平均高度 × 索引差（冷缓存的比例估算）', () {
      double? none(int index) => null;
      double? at(int target) => estimateSignedContentOffset(
            targetIndex: target,
            centerIndex: 4,
            childCount: 10,
            cachedHeight: none,
            averageHeight: 30,
          );
      expect(at(4), 0);
      expect(at(0), -120, reason: '4 项 × 30');
      expect(at(9), 150, reason: '5 项 × 30');
    });

    test('部分缓存：已缓存用实测、未缓存用均值', () {
      final heights = <int, double>{1: 500};
      double? heightOf(int index) => heights[index];
      // centerIndex=3、target=0：经过 index 0/1/2 → 均值 + 500 + 均值
      expect(
        estimateSignedContentOffset(
          targetIndex: 0,
          centerIndex: 3,
          childCount: 6,
          cachedHeight: heightOf,
          averageHeight: 100,
        ),
        -700,
      );
    });

    test('估算只取决于目标与 center 的索引差（prepend 后仍同号同值）', () {
      double? none(int index) => null;
      final shallow = estimateSignedContentOffset(
        targetIndex: 0,
        centerIndex: 5,
        childCount: 10,
        cachedHeight: none,
        averageHeight: 40,
      );
      final deep = estimateSignedContentOffset(
        targetIndex: 0,
        centerIndex: 5,
        childCount: 30,
        cachedHeight: none,
        averageHeight: 40,
      );
      expect(shallow, -200);
      expect(deep, -200);
    });

    test('参数不可用时返回 null（childCount / 均值非法）', () {
      double? none(int index) => null;
      expect(
        estimateSignedContentOffset(
          targetIndex: 1,
          centerIndex: 0,
          childCount: 0,
          cachedHeight: none,
          averageHeight: 10,
        ),
        isNull,
      );
      expect(
        estimateSignedContentOffset(
          targetIndex: 1,
          centerIndex: 0,
          childCount: 4,
          cachedHeight: none,
          averageHeight: 0,
        ),
        isNull,
      );
      expect(
        estimateSignedContentOffset(
          targetIndex: 1,
          centerIndex: 0,
          childCount: 4,
          cachedHeight: none,
          averageHeight: double.nan,
        ),
        isNull,
      );
    });
  });
}
