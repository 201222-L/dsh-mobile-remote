// issue #24：对话轮次导航 —— 纯逻辑（无 Flutter 依赖，便于单测）。
//
// 「轮次索引」是**派生结构**：由会话事件折叠得出轮次号 → 该轮起始事件的持久序号。
// 会话日志里不存在用户编写的轮次元数据，本文件也不持有任何状态（见 ADR 0018）。
//
// 抽成无 Flutter 依赖的纯函数，理由与 `chat_copy.dart` 相同：折叠规则（边界推进、
// 预览归属、空白归一、截断）是容易写错又必须与电脑端一致的部分，必须在没有 widget
// 树的测试里钉死。

import 'dart:math' as math;

/// 一轮在刻度轨上的定位信息。
///
/// [seq] 是该轮 `turn/start` 事件的持久序号——它天然就是"定位到这一轮"的锚点，
/// 与电脑端刻度轨及分页语义一致。
class TurnAnchor {
  const TurnAnchor({
    required this.turn,
    required this.seq,
    this.prompt = '',
    this.response = '',
  });

  /// 宿主分配的轮次号（`turn/start` 载荷里的 `turn`）。
  final int turn;

  /// 该轮起始事件的持久序号（定位锚点）。
  final int seq;

  /// 提示词预览（已归一化、已截断）。
  final String prompt;

  /// 回复预览（已归一化、已截断）。
  final String response;

  @override
  bool operator ==(Object other) =>
      other is TurnAnchor &&
      other.turn == turn &&
      other.seq == seq &&
      other.prompt == prompt &&
      other.response == response;

  @override
  int get hashCode => Object.hash(turn, seq, prompt, response);

  @override
  String toString() =>
      'TurnAnchor(turn: $turn, seq: $seq, prompt: "$prompt", response: "$response")';
}

/// 折叠输入行的角色。只有真人提示词与助手回复参与预览。
enum TurnRowRole { user, assistant, other }

/// 折叠输入的一行。调用方必须按**时间正序**提供全部已加载条目。
class TurnRow {
  const TurnRow({
    this.boundaryTurn,
    this.seq,
    this.role = TurnRowRole.other,
    this.text = '',
  });

  /// 轮次边界行携带的轮次号；非边界行为 null。
  ///
  /// 只有 `turn/start` 产生边界：`turn/end` 不推进轮次号，只表示该轮结束，
  /// 因此不需要单独表达（回复预览在轮内最后一条助手消息时就已落定）。
  final int? boundaryTurn;

  /// 边界行的持久序号（定位锚点）；非 boundary 行为 null。
  final int? seq;

  final TurnRowRole role;
  final String text;
}

/// 提示词预览预算（与电脑端刻度轨一致：50 字符封顶）。
const int kTurnPromptMaxChars = 50;

/// 回复预览预算（与电脑端刻度轨一致：120 字符封顶）。
const int kTurnResponseMaxChars = 120;

/// 刻度轨显隐判据。
///
/// - `nearBottom`：距底部 160px 内视为"停留最新"（复用「回到底部」圆钮的既有判据，
///   使两个控件同进同出）。
/// - `turnCount`：已知轮次数。少于 2 轮时不渲染——一轮没有导航价值，只是噪声。
bool shouldShowTurnRail({required bool nearBottom, required int turnCount}) =>
    !nearBottom && turnCount >= 2;

/// 预览文本归一化：折叠全部空白、去首尾、超长截断并补省略号。
///
/// 归一化是预览的**唯一入口**，保证同一轮在刻度气泡里显示的文字稳定，
/// 不因换行/缩进差异而跳动。
String normalizeTurnPreview(String raw, {required int maxChars}) {
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= maxChars) return flat;
  return '${flat.substring(0, maxChars)}…';
}

/// 从按时间正序的行折叠出轮次锚点（按轮次号严格升序）。
///
/// 规则（与电脑端轮次大纲一致）：
/// - 以 `turn/start` 为锚，**不**以提示词为锚——因为锚点的持久序号必须是分页目标；
/// - 未推进轮次号的边界被跳过，保持升序（重试边界不会产生重复刻度）；
/// - 提示词取该轮内**第一条**真人提示词（中途引导保留首个预览）；
/// - 回复取该轮内最后一条有文本的助手消息；
/// - 边界之前的散落消息不属于任何轮次，忽略。
List<TurnAnchor> foldTurnAnchors(Iterable<TurnRow> rows) {
  final out = <TurnAnchor>[];
  int? turn;
  int? seq;
  var prompt = '';
  var response = '';

  void commit() {
    final t = turn;
    final s = seq;
    if (t == null || s == null) return;
    out.add(TurnAnchor(turn: t, seq: s, prompt: prompt, response: response));
  }

  for (final row in rows) {
    final boundary = row.boundaryTurn;
    final boundarySeq = row.seq;
    if (boundary != null && boundarySeq != null) {
      final current = turn;
      // 未推进轮次号：跳过，绝不产生第二个同号刻度。
      if (current != null && boundary <= current) continue;
      commit();
      turn = boundary;
      seq = boundarySeq;
      prompt = '';
      response = '';
      continue;
    }
    if (turn == null) continue; // 边界之前：不属于任何轮次
    if (row.role == TurnRowRole.user) {
      if (prompt.isEmpty) {
        prompt = normalizeTurnPreview(row.text, maxChars: kTurnPromptMaxChars);
      }
    } else if (row.role == TurnRowRole.assistant) {
      final text =
          normalizeTurnPreview(row.text, maxChars: kTurnResponseMaxChars);
      if (text.isNotEmpty) response = text;
    }
  }
  commit();
  return out;
}

/// 当前轮判定：停留在最新位置时取最后一轮，否则取"跨过阅读线"的那一轮。
///
/// [mounted] 是**已构建**刻度的几何信息（屏幕外的懒构建条目不在其中），
/// [readingLine] 是阅读线在视口中的 y 坐标。
///
/// 取"起点不晚于阅读线的最后一个刻度"：若阅读线在所有刻度之上，退化为第一轮。
int? activeTurnFromMounted(
  List<({int turn, double top})> mounted, {
  required double readingLine,
}) {
  if (mounted.isEmpty) return null;
  int? candidate;
  for (final m in mounted) {
    if (m.top <= readingLine) {
      if (candidate == null || m.turn > candidate) candidate = m.turn;
    }
  }
  if (candidate != null) return candidate;
  // 阅读线在全部已构建刻度之上：取最靠上（最小 y）的那个。
  var best = mounted.first;
  for (final m in mounted) {
    if (m.top < best.top) best = m;
  }
  return best.turn;
}

/// 有界迭代定位的比例估算：把目标在子项中的序号线性映射到可滚动区间。
///
/// 这只是**第一次**落点，真实收敛靠"落点后用实测邻居修正"（见 `_jumpToTurn`）。
/// 因为条目高度可变，比例估算必然不准，所以它只用于把目标带进构建范围。
double estimateTurnOffset({
  required int targetIndex,
  required int childCount,
  required double minScrollExtent,
  required double maxScrollExtent,
}) {
  if (childCount <= 1) return maxScrollExtent;
  final clamped = targetIndex.clamp(0, childCount - 1);
  final ratio = clamped / (childCount - 1);
  return minScrollExtent + (maxScrollExtent - minScrollExtent) * ratio;
}

/// 有界迭代定位的最大尝试次数。
///
/// **为什么是 24**（issue #31 真机缺陷）：没有尺寸缓存时，目标在很远处的定位退化为
/// 区间二分，需要约 `log2(条目数)` 步——3000 条要 ~12 步，旧的 6 步会以
/// 「多次尝试后仍未进入视图」失败（真机上第 2 轮离底部约 2900 个条目）。现在
/// [TurnLocator.estimateOffsetForIndex] 提供了"索引→偏移"的估算（本体虚拟化列表
/// `getOffsetForIndex` 的等价物），常见长跳 1–3 步即收敛；24 步只是**冷缓存 + 条目
/// 高度极端不均匀**时的兜底。区间只收不放、落点重复即转降级搜索，因此多给预算不会
/// 死循环，只是给收敛留够余量。
const int kTurnLocateMaxAttempts = 24;

/// 定位的**绝对**时间安全网（毫秒）。
///
/// 上界本来是"尝试次数"（[kTurnLocateMaxAttempts]，每次尝试真的落点一帧）；
/// 这个墙钟只兜住每帧都极慢的病态情形。历史和教训：这里原先是一个 4 秒的收敛预算，
/// 但大量 prepend 之后单帧布局就可能 >1 秒，4 秒会在**正在收敛途中**误报
/// 「多次尝试后仍未进入视图」（issue #31 复审实测：落点已前进到 -215908 仍被判停滞）。
const int kTurnLocateHardCapMs = 20000;

/// 判定"落点重复 / 振荡"的偏移容差（像素）。
///
/// 落点落在同一个位置（±容差）说明按索引估算已不再产生信息，继续重复只会
/// 把剩余次数耗在同一对位置之间（#24 复审实测的 `22464 ↔ 4759` 就是这样）。
const double kTurnLocateRepeatEpsilon = 1.0;

/// 降级搜索：沿目标方向按**视口高度的这个比例**步进。
///
/// 只有在区间二分也产生不出新落点（区间已小于容差）时才用它。
const double kTurnLocateStepFactor = 0.9;

/// 视口高度不可用时的降级步长（像素）。
const double kTurnLocateFallbackStep = 200.0;

/// 目标进入视口后停留的阅读线比例（与页面侧 `ensureVisible` 的 alignment 一致）。
const double kTurnLocateReadingLineFactor = 0.1;

/// 一个**已构建**子项的实测几何：内容顺序索引 + 内容坐标偏移 + 高度。
///
/// 与 [TurnMeasurement] 的区别：后者按**轮次号**记录轮次**边界**的几何（给定位的
/// 比例兜底与高亮缓存用），而本类按**内容顺序索引**记录任意已构建条目。懒构建 +
/// 可变高度下，目标是"在前还是在后"必须用真实索引判断：一轮 14,400 字的回复会把
/// 轮次平均步距彻底带偏，而内容顺序索引与内容偏移是单调的，据此维护的上下界才收得拢。
///
/// ⚠ 调用方必须传**内容顺序**索引，不能用 sliver 内的子项序号：`center` 锚点下
/// center 之前那条列表的子项序号越大越靠上（内容偏移越小），方向正好相反。
class BuiltChildMeasurement {
  const BuiltChildMeasurement({
    required this.index,
    required this.offset,
    this.height = 0,
  });

  /// 该子项在**内容顺序**里的位置（与 `targetIndex` 同一坐标系，越大越靠后）。
  final int index;

  /// 该子项在滚动内容坐标系里的偏移（= `pixels` + 相对视口顶部的 dy）。
  final double offset;

  /// 该子项的实测高度；0 表示未知（此时索引只提供 offset 一侧的界）。
  ///
  /// 它是长回复场景的关键：一个 14,400 字的回复可以横跨上万个像素，目标若在它
  /// **之后**，"目标的偏移 ≥ 该子项底部（offset + height）"才是有信息量的下界；
  /// 只用顶部会把搜索区间留在目标上方很远，二分几乎不前进（#24 复审实测）。
  final double height;

  /// 该子项在内容坐标里的底部。
  double get bottom => offset + height;

  @override
  String toString() =>
      'BuiltChildMeasurement(index: $index, offset: $offset, height: $height)';
}

List<BuiltChildMeasurement> _noBuiltChildren() => const [];
double _zeroExtent() => 0;

/// 一个**已构建**轮次边界的实测几何。
///
/// [offset] 是该边界在滚动内容坐标系里的偏移（= 当前 `pixels` + 边界相对视口顶部的
/// dy）。它可以在不同落点之间比较、插值——这正是「按实际落点校正」的依据。
class TurnMeasurement {
  const TurnMeasurement({required this.turn, required this.offset});

  final int turn;
  final double offset;
}

/// 定位失败的原因（两者提示文案不同，调用方必须区分）。
enum TurnLocateFailure {
  /// 目标持久序号根本不在已加载窗口内（例如已翻出窗口 / 属于未分页的更早部分）。
  notInWindow,

  /// 目标在窗口内，但有界尝试次数或截止时间用尽仍未把它带进视口。
  exhausted,
}

/// 定位结果：成功（目标与视口相交）或带有明确原因的失败。
class TurnLocateOutcome {
  const TurnLocateOutcome.ok() : ok = true, failure = null;
  const TurnLocateOutcome.failed(TurnLocateFailure this.failure) : ok = false;

  final bool ok;
  final TurnLocateFailure? failure;
}

/// 用实测点估算「把 [targetTurn] 带进视口」所需的内容偏移。
///
/// 规则（按可信度降级）：
/// 1. 目标被两个实测点夹逼 → 在两者之间线性插值；
/// 2. 只有目标之前 / 之后的实测点 → 用最近两个实测点做割线外推；
/// 3. 一个实测点都没有 → 退回 [estimateTurnOffset] 的比例估算（兜底）。
///
/// 实测点的 [TurnMeasurement.offset] 已经是内容坐标，因此返回值也是内容坐标。
double estimateTurnOffsetFromMeasurements({
  required int targetTurn,
  required List<TurnMeasurement> measurements,
  required int targetIndex,
  required int childCount,
  required double minScrollExtent,
  required double maxScrollExtent,
}) {
  final sorted = [...measurements]..sort((a, b) => a.turn.compareTo(b.turn));
  TurnMeasurement? before;
  TurnMeasurement? after;
  for (final m in sorted) {
    if (m.turn <= targetTurn && (before == null || m.turn > before.turn)) {
      before = m;
    }
    if (m.turn >= targetTurn && (after == null || m.turn < after.turn)) {
      after = m;
    }
  }
  if (before != null && after != null) {
    if (before.turn == after.turn) return before.offset;
    final f = (targetTurn - before.turn) / (after.turn - before.turn);
    return before.offset + (after.offset - before.offset) * f;
  }
  if (before != null) {
    final slope = _secantSlope(sorted, targetTurn, useBefore: true);
    if (slope != null) return before.offset + slope * (targetTurn - before.turn);
  }
  if (after != null) {
    final slope = _secantSlope(sorted, targetTurn, useBefore: false);
    if (slope != null) return after.offset - slope * (after.turn - targetTurn);
  }
  return estimateTurnOffset(
    targetIndex: targetIndex,
    childCount: childCount,
    minScrollExtent: minScrollExtent,
    maxScrollExtent: maxScrollExtent,
  );
}

/// 每个刻度在内容坐标里的平均步距（最近两点割线）；点数不足或斜率非正时返回 null。
double? _secantSlope(
  List<TurnMeasurement> sorted,
  int targetTurn, {
  required bool useBefore,
}) {
  final candidates = useBefore
      ? sorted.where((m) => m.turn < targetTurn).toList()
      : sorted.where((m) => m.turn > targetTurn).toList();
  if (candidates.length < 2) return null;
  final TurnMeasurement a;
  final TurnMeasurement b;
  if (useBefore) {
    a = candidates[candidates.length - 1];
    b = candidates[candidates.length - 2];
  } else {
    a = candidates[0];
    b = candidates[1];
  }
  if (a.turn == b.turn) return null;
  final slope = (a.offset - b.offset) / (a.turn - b.turn);
  return slope > 0 ? slope : null;
}

/// 内容索引 → 该行的**已缓存高度**；未缓存返回 null。
typedef CachedRowHeight = double? Function(int index);

/// 按**内容顺序**估算目标顶部相对列表 `center` 的**有符号偏移**（issue #31 复审修订）。
///
/// 本体虚拟化列表用 `itemSizeCache + estimateSize` 做 `getOffsetForIndex`；这里用同样的
/// 两段式算前缀高度（已缓存实测高度优先、未缓存用均值兜底），再**减去 center 处的前缀**——
/// 这一步是必需的：`CustomScrollView.center` 之前（older 侧）的条目在**负坐标**，
/// center 之后才是正坐标；直接返回"从最早条目起累加的非负前缀"根本不在定位器的坐标系里
/// （复审给的核对例：older 只有一条高 100 的消息时，live 首条实际 top=0、older 首条实际
/// top=-100，而非负前缀会给出 100 与 0）。
///
/// @param targetIndex 目标的内容索引。
/// @param centerIndex center 处的内容索引（live 侧第一条消息）。
/// @param childCount 内容顺序下的子项总数（含按钮/加载条等非消息行）。
/// @param cachedHeight 该内容索引的已缓存高度（未缓存传 null）。
/// @param averageHeight 未缓存行的回退高度（缓存实测均值，或 `extent / childCount`）。
/// @returns 有符号的内容偏移；参数不可用时返回 null。
double? estimateSignedContentOffset({
  required int targetIndex,
  required int centerIndex,
  required int childCount,
  required CachedRowHeight cachedHeight,
  required double averageHeight,
}) {
  if (childCount <= 0 || !averageHeight.isFinite || averageHeight <= 0) {
    return null;
  }
  double prefix(int index) {
    var sum = 0.0;
    for (var i = 0; i < index; i++) {
      final height = cachedHeight(i);
      sum += (height != null && height > 0) ? height : averageHeight;
    }
    return sum;
  }

  return prefix(targetIndex) - prefix(centerIndex);
}

/// 有界迭代定位的执行器。
///
/// 把「估算 → 落点 → 检查目标是否真的进入视口」这条控制流从页面里抽出来：它是最
/// 容易写错、也最需要回归保护的部分（懒构建 + center 锚点 + 条目高度可变）。本类
/// **不依赖 Flutter**，几何与副作用全部由回调注入，因此既能被真实列表驱动，
/// 也能用假回调做边界测试。
///
/// 收敛机制（issue #24 复审后修订）：
/// - [measureBuilt] 给出**已构建子项的真实索引与内容偏移**，据此维护搜索区间
///   `[lo, hi]`：索引小于目标的实测点抬高 `lo`，大于目标的压低 `hi`；目标被两个
///   实测点夹逼时按**索引**线性插值，比"轮次平均步距"稳得多。
/// - 一次定位内保留这个区间与已访问落点；目标已构建时直接用它的**实测内容偏移**
///   把阅读线对准它（精确一跳，不依赖动画）。
/// - 落点重复 / 振荡时改走有进展的降级搜索：优先在 `[lo, hi]` 内二分，否则沿已知
///   目标方向按视口比例步进，而不是把剩余次数耗在同一对位置之间。
/// - 次数（[maxAttempts]）与时间（[timeout]）预算不变；成功判据始终是
///   [isTargetInView]（目标与视口相交），不是"已构建"。
class TurnLocator {
  TurnLocator({
    required this.scrollTo,
    required this.minScrollExtent,
    required this.maxScrollExtent,
    required this.isTargetLoaded,
    required this.isTargetBuilt,
    required this.isTargetInView,
    required this.reveal,
    required this.measure,
    required this.settle,
    this.measureBuilt = _noBuiltChildren,
    this.estimateOffsetForIndex,
    this.currentOffset = _zeroExtent,
    this.viewportExtent = _zeroExtent,
    this.maxAttempts = kTurnLocateMaxAttempts,
    this.timeout = const Duration(milliseconds: kTurnLocateHardCapMs),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 跳到某个可滚动偏移。
  final void Function(double offset) scrollTo;
  final double Function() minScrollExtent;
  final double Function() maxScrollExtent;

  /// 当前滚动偏移（降级步进的起点）。未接线时按 0 处理。
  final double Function() currentOffset;

  /// 视口高度（降级步长按它取比例）。未接线时按 0 处理。
  final double Function() viewportExtent;

  /// 目标（按持久 seq 绑定的那个规范边界）是否仍在已加载窗口内。
  ///
  /// 这是 [TurnLocateFailure.notInWindow] 与 [TurnLocateFailure.exhausted] 的分界。
  final bool Function() isTargetLoaded;

  /// 目标是否已经构建（懒构建下这是「能不能精调」的判据）。
  final bool Function() isTargetBuilt;

  /// 目标是否与视口相交——**唯一的成功判据**（「已构建」可能是缓存区里的条目）。
  final bool Function() isTargetInView;

  /// 目标已构建但量不到几何时做一次精调（页面侧是 `Scrollable.ensureVisible`）。
  final Future<void> Function() reveal;

  /// 已构建轮次边界的实测几何（比例兜底用；页面侧顺带刷新高亮缓存）。
  final List<TurnMeasurement> Function() measure;

  /// 已构建**子项**的实测几何（真实索引 + 内容偏移）——搜索区间与方向的依据。
  ///
  /// 未接线时返回空列表，定位退回 [measure] 的轮次边界估算（旧行为）。
  final List<BuiltChildMeasurement> Function() measureBuilt;

  /// 内容索引 → **该子项顶部的内容偏移估算**（issue #31 方案 B）。
  ///
  /// 这是本体虚拟化列表 `getOffsetForIndex` 的等价物：页面侧用"条目尺寸缓存"（已构建
  /// 子项的实测高度，按稳定 key 记录）+ 平均值兜底算前缀高度和，因此**不必先跳过去**
  /// 就能估出目标的偏移。冷缓存时它退化为 `extent / childCount` 的比例估算（仍远优于
  /// 盲二分：目标在 20% 处就估 20%，而不是先跳 50%）。
  ///
  /// **坐标系**：必须是 `CustomScrollView.center` 的相对偏移（older 侧为负、live 侧为正），
  /// 与 [measureBuilt] 给出的内容偏移同一坐标系；页面侧用
  /// [estimateSignedContentOffset] 保证这一点（复审 P2：非负前缀会让估算整体平移、
  /// 永远通不过 `(lo, hi)` 判据）。
  ///
  /// 返回值只在"可信"时才被采用：必须严格落在当前搜索区间 `(lo, hi)` 内；否则退回
  /// 区间二分等既有策略。落点之后仍以实测几何校正，估算错了也不会跑偏。
  final double? Function(int index)? estimateOffsetForIndex;

  /// 等待一帧，让新落点处的条目完成构建与布局。
  final Future<void> Function() settle;

  final int maxAttempts;

  /// **绝对**时间安全网（默认 [kTurnLocateHardCapMs]）。
  ///
  /// 定位的真正上界是 [maxAttempts]（每次尝试都真的落点并等一帧）；这个墙钟只兜住
  /// "每帧都极慢"的病态情形。**不要**把它当成收敛预算：issue #31 复审实测证明，
  /// 用"多久没进展"或固定 4 秒当上界，会在真机/CI 负载下把慢帧误判成停滞、
  /// 在明明还在靠近目标时误报「多次尝试后仍未进入视图」。
  final Duration timeout;

  final DateTime Function() _clock;

  /// 尝试把 [targetTurn] 带进视口。
  ///
  /// 返回 [TurnLocateOutcome]；失败原因由 [TurnLocateFailure] 区分，**调用方必须
  /// 把这个结果如实告诉用户**，不得静默停下。
  Future<TurnLocateOutcome> locate({
    required int targetTurn,
    required int targetIndex,
    required int childCount,
  }) async {
    if (!isTargetLoaded()) {
      return const TurnLocateOutcome.failed(TurnLocateFailure.notInWindow);
    }
    if (isTargetInView()) return const TurnLocateOutcome.ok();
    final start = _clock();
    // 上界是**尝试次数**（每次尝试都真的落点并等一帧），墙钟只作绝对安全网：
    // 用"多久没进展"当上界在真机/CI 负载下会把慢帧误判成停滞、在收敛途中放弃
    // （issue #31 复审实测：落点已从 -121471 前进到 -215908 仍被判停滞）。
    bool timedOut() => _clock().difference(start) >= timeout;

    // 搜索界（issue #31 复审 P1 修订）：
    // **只持久化实测约束**——来自真实已构建子项的界（索引更小者的底部 = 下界；索引更大
    // 者的顶部 = 上界）。prepend 更早历史会把 older 侧所有偏移**整体**推得更负，内容顺序
    // 关系不变，因此这两个不等式不会被打破，跨轮保留还能持续收窄（丢了它搜索会在两个区域
    // 之间振荡：复审前那版"每轮重算"就退化成这样）。
    // **布局估计不持久化**：`minScrollExtent()` 只是懒布局的动态估计，把它当成"永久实测
    // 下界"正是复审 P1 的病灶（目标约 -215000，冻结下界却停在 -10 附近）。因此只在还没有
    // 实测下界时，用**当前这一轮**的布局下界兜底。
    double? measuredLower;
    double? measuredUpper;
    final visited = <double>[];

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (timedOut()) {
        return const TurnLocateOutcome.failed(TurnLocateFailure.exhausted);
      }
      final min = minScrollExtent();
      final max = maxScrollExtent();
      final viewport = viewportExtent();
      final built = measureBuilt();
      // 页面侧借这次采样刷新轮次边界缓存（高亮用）；同时是无 measureBuilt 时的兜底。
      final boundaries = measure();

      int? beforeIndex;
      double? beforeOffset;
      int? afterIndex;
      double? afterOffset;
      double? targetOffset;
      for (final b in built) {
        if (b.index == targetIndex) {
          targetOffset = b.offset;
        } else if (b.index < targetIndex) {
          if (beforeIndex == null || b.index > beforeIndex) {
            beforeIndex = b.index;
            beforeOffset = b.offset;
          }
          // 目标在该子项之后 → 目标偏移 ≥ 它的底部（持久化，只收不放）。
          if (measuredLower == null || b.bottom > measuredLower) measuredLower = b.bottom;
        } else {
          if (afterIndex == null || b.index < afterIndex) {
            afterIndex = b.index;
            afterOffset = b.offset;
          }
          // 目标在该子项之前 → 目标偏移 ≤ 它的顶部（持久化，只收不放）。
          if (measuredUpper == null || b.offset < measuredUpper) measuredUpper = b.offset;
        }
      }

      // 进展判定在**选完探针之后**做（见下）；这里不要提前更新 previous*，
      // 否则判据会拿本轮的值和本轮比，永远不认为有进展。
      if (targetOffset != null) {
        // 目标已构建：它的真实内容偏移已知，直接把阅读线对准它——精确一跳，
        // 不受 `ensureVisible` 动画与后续 `jumpTo` 互相打断的影响。
        final exact = (targetOffset - viewport * kTurnLocateReadingLineFactor)
            .clamp(min, max)
            .toDouble();
        if (!_isRepeat(exact, visited)) {
          scrollTo(exact);
          visited.add(exact);
        }
        if (await _settleUntilInView()) return const TurnLocateOutcome.ok();
        if (timedOut()) {
          return const TurnLocateOutcome.failed(TurnLocateFailure.exhausted);
        }
      } else if (isTargetBuilt()) {
        // 已构建但量不到几何（渲染对象尚未布局完）：退回 ensureVisible 精调。
        await reveal();
        if (await _settleUntilInView()) return const TurnLocateOutcome.ok();
        if (timedOut()) {
          return const TurnLocateOutcome.failed(TurnLocateFailure.exhausted);
        }
      }

      // 有效界：实测优先；尚无实测下界时才用**当前**布局下界（每轮重读，允许向负扩展）。
      final lowerBound = measuredLower ?? min;
      final upperBound = measuredUpper;
      final lower = math.max(lowerBound, min);
      final upper = math.max(math.min(upperBound ?? max, max), lower);
      var probe = _selectProbe(
        targetTurn: targetTurn,
        targetIndex: targetIndex,
        childCount: childCount,
        beforeIndex: beforeIndex,
        beforeOffset: beforeOffset,
        afterIndex: afterIndex,
        afterOffset: afterOffset,
        lo: lowerBound,
        hi: upperBound,
        min: min,
        max: max,
        boundaries: boundaries,
      ).clamp(lower, upper).toDouble();
      if (_isRepeat(probe, visited)) {
        // 重复 / 振荡：改走有进展的降级搜索，而不是把剩余次数耗在同一对位置。
        // 此时**不再**夹回 [lo, hi]——区间本身已经被证伪（例如两端的实测点把目标
        // 夹成一个点，而那里并没有目标），只有放宽到真实可滚动范围才可能前进。
        probe = _degradedProbe(
          visited: visited,
          lower: lower,
          upper: upper,
          targetAbove: afterOffset != null,
          targetBelow: beforeOffset != null,
          viewport: viewport,
        ).clamp(min, max).toDouble();
      }

      scrollTo(probe);
      visited.add(probe);
      if (await _settleUntilInView()) return const TurnLocateOutcome.ok();
    }
    // **尾部**（loop 内每轮入口已有同样检查，这里补的是"没有下一轮"的情形）：
    // 最后一次落点后的等待可能正好跨过绝对安全网；此时不得再发起 reveal 精调或继续等待，
    // 否则"硬截止"之后仍会有滚动副作用（issue #31 三轮复审实测：cap=20s 时在 24s 又
    // reveal 一次）。
    if (timedOut()) {
      return const TurnLocateOutcome.failed(TurnLocateFailure.exhausted);
    }
    // 次数用尽前再给布局一点时间：大列表 prepend 之后"落点对了但目标还没布局完"
    // 是常见情形，只等一帧就报失败会给出假的「未能定位」（issue #31 复审）。
    if (isTargetBuilt()) {
      await reveal();
    }
    if (await _settleUntilInView(frames: 4)) {
      return const TurnLocateOutcome.ok();
    }
    return const TurnLocateOutcome.failed(TurnLocateFailure.exhausted);
  }

  /// 有界地等布局稳定并复查目标是否进入视口。
  ///
  /// 懒构建 + 大列表下，"滚动到位"与"目标真的被布局进视口"之间可能差好几帧；
  /// 固定只等一帧会在负载下误报失败。这里最多等 [frames] 帧，且每帧先复查一次。
  Future<bool> _settleUntilInView({int frames = 3}) async {
    for (var i = 0; i < frames; i++) {
      if (isTargetInView()) return true;
      await settle();
    }
    return isTargetInView();
  }

  /// 选下一个落点（未做区间夹紧与重复检测）。
  ///
  /// 可信度降级：
  /// 1. 目标被两个实测子项夹逼 → 按**索引**线性插值；
  /// 2. 只有"目标之后"的实测点（目标在上方）→ 在 lo 与该点之间二分；
  /// 3. 只有"目标之前"的实测点（目标在下方）→ 在该点与 hi（或 max）之间二分；
  /// 4. 没有任何实测 → 退回轮次边界的比例 / 割线估算（旧行为，也是首跳）。
  double _selectProbe({
    required int targetTurn,
    required int targetIndex,
    required int childCount,
    required int? beforeIndex,
    required double? beforeOffset,
    required int? afterIndex,
    required double? afterOffset,
    required double lo,
    required double? hi,
    required double min,
    required double max,
    required List<TurnMeasurement> boundaries,
  }) {
    if (beforeOffset != null && afterOffset != null) {
      final i0 = beforeIndex!;
      final i1 = afterIndex!;
      final span = (i1 - i0).toDouble();
      final frac = span <= 0 ? 0.5 : (targetIndex - i0) / span;
      return beforeOffset + (afterOffset - beforeOffset) * frac.clamp(0.0, 1.0);
    }
    // 尺寸缓存的"索引→偏移"估算：目标在很远处的常见情形下比盲二分准得多。
    // 只在严格落在区间 (lo, hi) 内时采用——区间外说明估算已被实测证伪。
    final estimate = estimateOffsetForIndex?.call(targetIndex);
    final usableEstimate = estimate != null &&
        estimate.isFinite &&
        estimate > lo &&
        (hi == null || estimate < hi);
    if (afterOffset != null) {
      // 目标在实测点上方：优先用估算，否则在区间下界与该点之间二分（下界可能是列表顶端）。
      if (usableEstimate) return estimate;
      return (lo + afterOffset) / 2;
    }
    if (beforeOffset != null) {
      final upper = hi ?? max;
      // 目标在实测点下方：估算必须在实测点之下才有意义。
      if (usableEstimate && estimate > beforeOffset) return estimate;
      return upper > lo ? (lo + upper) / 2 : lo;
    }
    if (usableEstimate) return estimate;
    return estimateTurnOffsetFromMeasurements(
      targetTurn: targetTurn,
      measurements: boundaries,
      targetIndex: targetIndex,
      childCount: childCount,
      minScrollExtent: min,
      maxScrollExtent: max,
    );
  }



  /// 降级搜索：区间二分优先，其次沿已知目标方向按视口比例步进。
  double _degradedProbe({
    required List<double> visited,
    required double lower,
    required double upper,
    required bool targetAbove,
    required bool targetBelow,
    required double viewport,
  }) {
    if (upper - lower > kTurnLocateRepeatEpsilon * 2) {
      final mid = (lower + upper) / 2;
      if (!_isRepeat(mid, visited)) return mid;
    }
    final step = viewport > 0
        ? viewport * kTurnLocateStepFactor
        : kTurnLocateFallbackStep;
    final base = visited.isEmpty ? currentOffset() : visited.last;
    if (targetAbove) {
      for (var k = 1; k <= 3; k++) {
        final candidate = base - step * k;
        if (!_isRepeat(candidate, visited)) return candidate;
      }
    } else if (targetBelow) {
      for (var k = 1; k <= 3; k++) {
        final candidate = base + step * k;
        if (!_isRepeat(candidate, visited)) return candidate;
      }
    }
    // 方向未知（一个实测点都没有）：退回区间中点。
    return (lower + upper) / 2;
  }

  static bool _isRepeat(double probe, List<double> visited) {
    for (final v in visited) {
      if ((v - probe).abs() <= kTurnLocateRepeatEpsilon) return true;
    }
    return false;
  }
}
