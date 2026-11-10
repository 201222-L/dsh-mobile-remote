import 'l10n.dart';
import 'models.dart';
import 'timeline.dart' show timelineIsInjectedNoise;

/// issue #52（ADR 0027 §2）：轮次过程折叠与工作步骤展示模式的**唯一规则实现**。
///
/// 本文件只做纯投影，不依赖 Flutter：从服务端事件（[ChatEvent]）折叠出
/// 「轮次 → 过程组（按事件 `step` 派生）→ 过程行（思考/工具调用）」结构，
/// 并提供展示模式、收起时机、强制展开、用时文案与分批规则。
/// ChatScreen 只负责把这里算出的结构渲染出来，不再复刻判据。
///
/// 事件可能按任意顺序到达（历史最新在前、实时正序、分页重叠），因此折叠过程
/// 全部是**顺序无关**的：按 seq/时间取极值，按 callId 去重，渲染前再按 seq 排序。

/// 工作步骤展示模式四档（信息密度，不是普通/调试模式的可见性开关）。
enum WorkStepDisplayMode { concise, standard, detailed, expanded }

/// 收起时机两档：回答结束后立即收起，或等下一次有新消息（含远端）时再收起。
enum TurnFoldTiming { afterAnswer, onNewMessage }

// ── issue #70（ADR 0027 §2 实时态）：运行中思考（provisional）的流式缓冲 ──────
//
// 分层同 ADR 0027：`TurnProcessTracker` 只承载**持久**事件投影；流式 reasoning
// 是纯渲染态，单独放在本文件的 [LiveReasoningBuffer]（不依赖 Flutter，可单测）。
// 活动条与过程块的 provisional 行读同一份 [LiveReasoning] 快照，不存在第二份文本。

/// 运行中思考缓冲的快照（不可变，供渲染层与活动条同源读取）。
class LiveReasoning {
  const LiveReasoning({
    required this.turn,
    required this.step,
    required this.text,
    required this.chars,
    required this.firstSeq,
  });

  final int turn;
  final int? step;
  final String text;

  /// `text.length`（UTF-16 code unit）；活动条与展开态标签共用同一口径。
  final int chars;

  /// 该 (turn, step) 首个 reasoning delta 的 seq。
  ///
  /// 落定后持久 reasoning 行的排序键继承它（[TurnProcessTracker.noteReasoningStart]），
  /// 保证「provisional 行 → 持久行」不发生上下跳位。
  final int firstSeq;
}

/// 运行中（provisional）思考缓冲：**唯一**流式来源。
///
/// 键 = `turn:step`（step 缺失时用 `turn:null`，与 tracker 的退化组同口径）：
/// - 同一轮只保留当前最大 step 的条目；更小 step 的迟到 chunk 一律丢弃；
/// - [closeStep]/[closeTurn] 写入关闭集合（tombstone），迟到 chunk 不会复活 provisional；
/// - [append] 返回 true 表示键集合发生**可见结构变化**（首现/切换），
///   调用方据此重建过程计划；纯文本增长返回 false（只通知行级 ValueNotifier）。
class LiveReasoningBuffer {
  final Map<String, _LiveEntry> _entries = {};
  final Set<String> _closedKeys = {};
  final Map<int, int> _closedMaxStep = {};
  final Set<int> _closedTurns = {};

  /// 无 seq 的 chunk（旧宿主/异常投影）用足够大的排序键：宁可排在尾部，也不打乱已有序。
  static const int _unknownSeq = 1 << 30;

  static String keyOf(int turn, int? step) => '$turn:${step ?? 'null'}';

  /// 该 (turn, step) 的首个 delta seq；没有活动条目返回 null。
  int? firstSeqOf(int turn, int? step) => _entries[keyOf(turn, step)]?.firstSeq;

  /// 当前应渲染的唯一 provisional：取最大轮次的最大 step（不同轮不可能同时流式）。
  LiveReasoning? get current {
    _LiveEntry? best;
    for (final entry in _entries.values) {
      if (best == null ||
          entry.turn > best.turn ||
          (entry.turn == best.turn && _stepRank(entry.step) > _stepRank(best.step))) {
        best = entry;
      }
    }
    return best?.snapshot();
  }

  /// 追加一段 delta；返回是否发生**可见结构变化**（需要重建过程计划）。
  bool append(int turn, int? step, String delta, {int? seq}) {
    LiveProcessCounters.appends++;
    final key = keyOf(turn, step);
    if (_closedTurns.contains(turn) || _closedKeys.contains(key)) return false;
    final closedMax = _closedMaxStep[turn];
    if (step != null && closedMax != null && step <= closedMax) return false;

    final sameTurn = <_LiveEntry>[
      for (final entry in _entries.values)
        if (entry.turn == turn) entry,
    ];
    if (sameTurn.isNotEmpty) {
      final entry = sameTurn.length == 1
          ? sameTurn.first
          : sameTurn.reduce(
              (a, b) => _stepRank(b.step) > _stepRank(a.step) ? b : a,
            );
      if (step == null) {
        // 未知 step 的迟到 chunk 不得覆盖已知 step（否则旧文本会混进新 step）。
        if (entry.step != null) return false;
        entry.write(delta);
        return false;
      }
      if (entry.step == null) {
        // 退化键 → 明确 step：关闭退化键并切换。
        _closeEntry(entry);
        _entries[key] = _LiveEntry(
          turn: turn,
          step: step,
          firstSeq: seq ?? _unknownSeq,
        )..write(delta);
        LiveProcessCounters.structuralChanges++;
        return true;
      }
      if (step < entry.step!) return false;
      if (step > entry.step!) {
        _closeEntry(entry);
        _entries[key] = _LiveEntry(
          turn: turn,
          step: step,
          firstSeq: seq ?? _unknownSeq,
        )..write(delta);
        LiveProcessCounters.structuralChanges++;
        return true;
      }
      entry.write(delta);
      return false;
    }

    // 该轮没有活动条目：不同轮不可能同时流式——更早轮一律关闭（迟到 chunk 丢弃）。
    if (_entries.isNotEmpty) {
      var maxTurn = -1;
      for (final entry in _entries.values) {
        if (entry.turn > maxTurn) maxTurn = entry.turn;
      }
      if (turn < maxTurn) return false;
      if (turn > maxTurn) {
        for (final entry in _entries.values.toList()) {
          if (entry.turn >= turn) continue;
          _closedTurns.add(entry.turn);
          _closeEntry(entry);
        }
      }
    }
    _entries[key] = _LiveEntry(
      turn: turn,
      step: step,
      firstSeq: seq ?? _unknownSeq,
    )..write(delta);
    LiveProcessCounters.structuralChanges++;
    return true;
  }

  /// 落定（`assistant/message`）：关闭该轮 step<=[settledStep] 与 step==null 的键。
  ///
  /// [settledStep] 缺失（旧内核/无 step 的 message）时关闭该轮全部活动键，并用被关闭的
  /// numeric step 作为上限挡住迟到 chunk（不波及后续更大 step 的正常流）。
  bool closeStep(int turn, int? settledStep) {
    var changed = false;
    var maxClosed = _closedMaxStep[turn];
    for (final entry in _entries.values.toList()) {
      if (entry.turn != turn) continue;
      final close = settledStep == null ||
          entry.step == null ||
          entry.step! <= settledStep;
      if (!close) continue;
      if (entry.step != null &&
          (maxClosed == null || entry.step! > maxClosed)) {
        maxClosed = entry.step;
      }
      _closeEntry(entry);
      changed = true;
    }
    // 退化组（step==null）始终写 tombstone：迟到 chunk 不得复活。
    _closedKeys.add(keyOf(turn, null));
    if (settledStep != null) {
      if (maxClosed == null || settledStep > maxClosed) maxClosed = settledStep;
    }
    if (maxClosed != null) {
      final prev = _closedMaxStep[turn];
      _closedMaxStep[turn] = prev == null || maxClosed > prev ? maxClosed : prev;
    }
    return changed;
  }

  /// 轮末/中断（`turn/end`，任意 reason）：关闭该轮全部键并整轮拒收迟到 chunk。
  bool closeTurn(int turn) {
    var changed = false;
    for (final entry in _entries.values.toList()) {
      if (entry.turn != turn) continue;
      _closeEntry(entry);
      changed = true;
    }
    _closedTurns.add(turn);
    return changed;
  }

  /// 切会话 / reset：清空一切（含关闭集合，避免跨会话串扰）。
  void clear() {
    _entries.clear();
    _closedKeys.clear();
    _closedMaxStep.clear();
    _closedTurns.clear();
  }

  /// live 窗口裁剪：丢掉 firstSeq 早于 [beforeSeq] 的条目，并回收更早轮的关闭集合。
  void pruneBefore(int beforeSeq) {
    _entries.removeWhere((_, entry) => entry.firstSeq < beforeSeq);
    if (_entries.isEmpty) return;
    var oldest = _unknownSeq;
    for (final entry in _entries.values) {
      if (entry.turn < oldest) oldest = entry.turn;
    }
    final floor = oldest - 1;
    _closedTurns.removeWhere((turn) => turn < floor);
    _closedMaxStep.removeWhere((turn, _) => turn < floor);
    _closedKeys.removeWhere((key) => _turnOfKey(key) < floor);
  }

  /// 关闭集合有界：只保留最近两轮的键（`turn/start` 推进 live 轮次时调用）。
  void trimClosedTurns(int liveTurn) {
    final floor = liveTurn - 1;
    _closedTurns.removeWhere((turn) => turn < floor);
    _closedMaxStep.removeWhere((turn, _) => turn < floor);
    _closedKeys.removeWhere((key) => _turnOfKey(key) < floor);
  }

  void _closeEntry(_LiveEntry entry) {
    _entries.remove(entry.key);
    _closedKeys.add(entry.key);
  }

  static int _stepRank(int? step) => step ?? -1;

  static int _turnOfKey(String key) {
    final index = key.indexOf(':');
    return int.tryParse(index < 0 ? key : key.substring(0, index)) ?? 0;
  }
}

/// 运行中思考行的折叠预览：取**最近一个非空行**（不是首行），**截断后总长 ≤ [max]**。
///
/// 与落定行的 [ProcessRow.reasoningPreview]（首行）刻意分开：运行中用户关心
/// 「现在想到哪」，落定后回到既有规则（issue #70 预审补充）。
///
/// 截断口径以 issue 预审的「截断（≤120 字符）」为准：超长时取 `max - 1` 个字符 +
/// 一个省略号（U+2026），即总长恰为 [max]；`/tmp/issue70-ui-spec.md` 的「120+…」
/// 写法会得到 121 字符，与 issue 冲突，按 issue 执行（审查 P2-1）。
String latestReasoningLinePreview(String text, {int max = 120}) {
  if (text.isEmpty) return '';
  final lines = text.split('\n');
  for (var i = lines.length - 1; i >= 0; i--) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (line.length <= max) return line;
    if (max <= 0) return '';
    return '${line.substring(0, max - 1)}…';
  }
  return '';
}

/// issue #70：仅测试/诊断用的计数钩子（**不参与业务判断**，生产路径只自增）。
///
/// 用途：证明「流式 delta 只更新该行，不重建整轮/整页计划」——200 个 delta 的
/// widget 用例据此断言重建次数上限（issue 预审补充「性能与滚动 / 测试补充」）。
class LiveProcessCounters {
  static int appends = 0;
  static int structuralChanges = 0;
  static int pageBuilds = 0;
  static int processPlanBuilds = 0;
  static int provisionalRowBuilds = 0;

  static void reset() {
    appends = 0;
    structuralChanges = 0;
    pageBuilds = 0;
    processPlanBuilds = 0;
    provisionalRowBuilds = 0;
  }
}

class _LiveEntry {
  _LiveEntry({
    required this.turn,
    required this.step,
    required this.firstSeq,
  });

  final int turn;
  final int? step;
  final int firstSeq;
  final StringBuffer _buffer = StringBuffer();

  String get key => LiveReasoningBuffer.keyOf(turn, step);
  int get chars => _buffer.length;
  void write(String delta) => _buffer.write(delta);

  LiveReasoning snapshot() => LiveReasoning(
        turn: turn,
        step: step,
        text: _buffer.toString(),
        chars: chars,
        firstSeq: firstSeq,
      );
}

/// 过程行种类：思维链与工具调用。
enum ProcessRowKind { reasoning, tool }

/// 过程行：轮次过程中呈现一次思考或一次工具调用的一行时间线条目。
class ProcessRow {
  final ProcessRowKind kind;
  final int seq;

  /// 宿主步骤边界；缺 step 的事件为 null（退化为整轮一组）。
  final int? step;

  /// 工具调用关联 id（tool 行）。
  final String? callId;
  final String? toolName;
  final String status;
  final bool isError;

  /// 思维链正文（reasoning 行；空串表示旧内核只给了字数）。
  final String reasoning;
  final int reasoningChars;

  const ProcessRow.reasoning({
    required this.seq,
    this.step,
    required this.reasoning,
    required this.reasoningChars,
  })  : kind = ProcessRowKind.reasoning,
        callId = null,
        toolName = null,
        status = 'complete',
        isError = false;

  const ProcessRow.tool({
    required this.seq,
    this.step,
    required this.callId,
    this.toolName,
    this.status = 'running',
    this.isError = false,
  })  : kind = ProcessRowKind.tool,
        reasoning = '',
        reasoningChars = 0;

  bool get isTool => kind == ProcessRowKind.tool;
  bool get isReasoning => kind == ProcessRowKind.reasoning;
  bool get running => isTool && status == 'running';

  /// 折叠态首行预览：思维链取首个非空行并按 [max] 截断。
  String reasoningPreview({int max = 120}) {
    for (final raw in reasoning.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      return line.length <= max ? line : '${line.substring(0, max)}…';
    }
    return '';
  }
}

/// 过程组：按宿主步骤边界聚合的一组过程行；折叠时由过程组抬头代表。
class ProcessGroup {
  /// null = 缺 step 的退化组（整轮一组）。
  final int? step;
  final List<ProcessRow> rows;

  const ProcessGroup({required this.step, required this.rows});

  int get toolCount => rows.where((r) => r.isTool).length;
  int get reasoningCount => rows.where((r) => r.isReasoning).length;
  int get reasoningChars =>
      rows.fold(0, (sum, r) => sum + r.reasoningChars);

  /// 组内还有正在跑的工具调用。
  bool get running => rows.any((r) => r.running);

  /// 组内存在失败的工具调用。
  bool get hasError => rows.any((r) => r.isError);
}

/// 轮次过程：一个轮次内由思考与工具调用组成的可见执行过程。
class TurnProcess {
  final int turn;

  /// 该轮 `turn/start` 的持久序号（渲染锚点，也是轮次导航的边界键）。
  final int startSeq;

  /// 该轮 `turn/end` 的持久序号；历史截断/仍在运行时为 null。
  final int? endSeq;

  final bool ended;

  /// `turn/end` 的 `reason.kind`（completed/aborted/interrupted/error…）。
  final String? endReasonKind;

  /// 轮次起止事件时间（Unix 毫秒，来自摘要顶层 `time`）；旧宿主为 null。
  final int? startedAtMs;
  final int? endedAtMs;

  final List<ProcessGroup> groups;

  /// 该轮期间出现的真人 user 消息 seq（用于切段与「轮内有插话」默认展开）。
  final List<int> humanUserSeqs;

  const TurnProcess({
    required this.turn,
    required this.startSeq,
    this.endSeq,
    this.ended = false,
    this.endReasonKind,
    this.startedAtMs,
    this.endedAtMs,
    this.groups = const [],
    this.humanUserSeqs = const [],
  });

  int get toolCount => groups.fold(0, (sum, g) => sum + g.toolCount);
  int get reasoningChars => groups.fold(0, (sum, g) => sum + g.reasoningChars);

  /// 单轮过程行总数（分批展示的上限基准）。
  int get rowCount => groups.fold(0, (sum, g) => sum + g.rows.length);

  /// 过程行按 seq 展开（组顺序 + 组内顺序），供分段与分批使用。
  List<ProcessRow> get rows => [
        for (final group in groups) ...group.rows,
      ];

  /// 轮内有插话：本轮边界内出现了真人 user 消息（含远端）。
  ///
  /// issue #79：插话只让该轮在「回答后」档**默认展开**（可手动折叠）；
  /// 运行中/异常结束才是硬强制展开，「下次有新消息」档仍按新消息自动收起。
  bool get hasInterjection => humanUserSeqs.any(
        (seq) => seq > startSeq && (endSeq == null || seq < endSeq!),
      );

  /// 异常结束（aborted/interrupted/error）：强制展开且不显示用时。
  bool get abnormalEnd => const {'aborted', 'interrupted', 'error'}
      .contains(endReasonKind);

  /// 强制展开（不看策略）：轮次未结束、异常结束。
  ///
  /// issue #79：轮内插话不再进入强制展开——结束后「回答后」档默认展开但可手动折叠；
  /// 运行中与 aborted/interrupted/error 仍不可折叠。
  bool get forceExpanded => !ended || abnormalEnd;

  /// 仅正常完成且两端的 `time` 都可用时才算用时；旧宿主/异常结束一律不显示。
  /// 桌面口径：`Math.max(1000, end - start)`（不足 1 秒按 1 秒显示）。
  int? get durationMs {
    if (!ended || abnormalEnd) return null;
    final start = startedAtMs;
    final end = endedAtMs;
    if (start == null || end == null || end < start) return null;
    final delta = end - start;
    return delta < 1000 ? 1000 : delta;
  }
}

/// 过程组折叠方式（对应桌面策略表 `stepGrouping` 三态）。
enum StepGrouping {
  /// 总是按 step 分组（运行中与历史都是过程组抬头）。
  collapsed,

  /// 只有已完成的轮按 step 分组；运行中的轮平铺过程行。
  history,

  /// 从不分组：整轮展开后过程行平铺。
  none,
}

/// 展示模式 → 折叠策略的映射表（issue #52 note 1700 / 桌面
/// `presentation-policy.js` 的 `foldCompletedTurns / stepGrouping /
/// liveProcessDetail / settledReasoningPreview` 四字段）。
///
/// 注意：**单张工具卡在所有档位默认收起**（桌面 useDisclosure 默认关闭），
/// 「完全展开」只影响整轮/过程组是否保持展开，不自动展开工具卡。
class TurnFoldPolicy {
  final WorkStepDisplayMode mode;
  final TurnFoldTiming timing;

  const TurnFoldPolicy({
    this.mode = WorkStepDisplayMode.standard,
    this.timing = TurnFoldTiming.afterAnswer,
  });

  /// 已完成整轮是否自动收起：简洁/标准/详细收起，只有完全展开不收起。
  bool get foldCompletedTurns => mode != WorkStepDisplayMode.expanded;

  /// 过程组折叠方式：简洁/标准总是按组；详细仅已完成轮按组；完全展开从不分组。
  StepGrouping get stepGrouping => switch (mode) {
        WorkStepDisplayMode.concise ||
        WorkStepDisplayMode.standard =>
          StepGrouping.collapsed,
        WorkStepDisplayMode.detailed => StepGrouping.history,
        WorkStepDisplayMode.expanded => StepGrouping.none,
      };

  /// 运行中的轮次是否展示过程细节（简洁/完全展开档只给一行摘要）。
  bool get liveProcessDetail =>
      mode == WorkStepDisplayMode.standard ||
      mode == WorkStepDisplayMode.detailed;

  /// 折叠态是否保留思维链首行预览（简洁档不留）。
  bool get settledReasoningPreview => mode != WorkStepDisplayMode.concise;

  /// 已完成的轮里，过程组是否以抬头（默认折叠）呈现。
  bool get groupsCollapsedByDefault => stepGrouping != StepGrouping.none;
}

/// 「下次有新消息」档的收起触发：该轮结束后出现了新的真人 user 消息。
bool newMessageArrivedAfter(TurnProcess turn, Iterable<int> humanUserSeqs) {
  final end = turn.endSeq;
  if (!turn.ended || end == null) return false;
  return humanUserSeqs.any((seq) => seq > end);
}

/// 整轮是否自动收起（不考虑用户手动覆盖；手动覆盖由界面层优先）。
bool turnAutoCollapsed(
  TurnProcess turn, {
  required TurnFoldPolicy policy,
  required Iterable<int> humanUserSeqs,
}) {
  if (turn.forceExpanded) return false;
  if (!policy.foldCompletedTurns) return false;
  switch (policy.timing) {
    case TurnFoldTiming.afterAnswer:
      // issue #79：轮内有插话 → 回答刚结束时保持默认展开（可手动折叠）；
      // 只影响「回答后」档，不让插话把「下次有新消息」档永久变成展开。
      if (turn.hasInterjection) return false;
      return true;
    case TurnFoldTiming.onNewMessage:
      return newMessageArrivedAfter(turn, humanUserSeqs);
  }
}

/// 已展开整轮内，过程组是否默认收起。
///
/// - 运行中的轮（只有「标准」档在运行中按组）：组**强制展开**（含底部最新组延后收起）。
/// - 已完成的轮：分组存在即默认折叠成抬头（简洁/标准/详细一致；完全展开不分组）。
bool groupAutoCollapsed(
  ProcessGroup group, {
  required TurnFoldPolicy policy,
  bool turnRunning = false,
}) {
  if (turnRunning) return false;
  return policy.groupsCollapsedByDefault;
}

/// 过程段：轮内被真人插话切开的一段过程行。
///
/// 事件序是 `turn/start → 提示词 user/message → 过程 → 回答`；轮内若再有真人插话，
/// 过程行会按插话切成多段，每段各自折叠（提示/插话 → 过程段 → 下一条插话 → …）。
class ProcessSegment {
  /// 段内过程行（按 seq 顺序）。
  final List<ProcessRow> rows;

  const ProcessSegment({required this.rows});

  bool get isEmpty => rows.isEmpty;
  int get startSeq => rows.first.seq;
  int get toolCount => rows.where((row) => row.isTool).length;
  int get reasoningChars => rows.fold(0, (sum, row) => sum + row.reasoningChars);

  /// 段内过程组：按 step 连续聚合（缺 step 退化为一段一组）。
  List<ProcessGroup> get groups {
    if (rows.isEmpty) return const [];
    final groups = <ProcessGroup>[];
    var current = <ProcessRow>[];
    int? currentStep;
    var started = false;
    void flush() {
      if (current.isEmpty) return;
      groups.add(ProcessGroup(step: currentStep, rows: List.unmodifiable(current)));
    }

    for (final row in rows) {
      if (!started || row.step != currentStep) {
        flush();
        current = <ProcessRow>[row];
        currentStep = row.step;
        started = true;
      } else {
        current.add(row);
      }
    }
    flush();
    return List.unmodifiable(groups);
  }

  /// 段折叠摘要（整段收起时替代过程块的一行）。
  String get summary {
    final parts = <String>[];
    if (reasoningChars > 0) parts.add('思考 $reasoningChars 字');
    parts.add(toolCount == 0
        ? '${groups.length} 个过程组'
        : '${groups.length} 组 · $toolCount 次工具调用');
    return parts.join(' · ');
  }
}

/// 按轮内插话（真人 user/message）把过程行切成段，供渲染层逐段折叠。
List<ProcessSegment> segmentsOf(TurnProcess turn) {
  final rows = turn.rows;
  if (rows.isEmpty) return const [];
  final boundaries = List<int>.from(turn.humanUserSeqs)..sort();
  final out = <ProcessSegment>[];
  var current = <ProcessRow>[];
  var boundaryIndex = 0;
  void flush() {
    if (current.isNotEmpty) {
      out.add(ProcessSegment(rows: List.unmodifiable(current)));
      current = <ProcessRow>[];
    }
  }

  for (final row in rows) {
    while (boundaryIndex < boundaries.length && row.seq > boundaries[boundaryIndex]) {
      flush();
      boundaryIndex++;
    }
    current.add(row);
  }
  flush();
  return List.unmodifiable(out);
}

const int processBatchSize = 50;

/// 单轮过程行分批窗口：展开后超过 [limit] 行时只呈现前 [limit] 行。
class ProcessBatchWindow {
  final List<ProcessRow> visible;
  final int hidden;
  final int total;

  const ProcessBatchWindow({
    required this.visible,
    required this.hidden,
    required this.total,
  });
}

/// 按轮次过程顺序（组顺序 + 组内 seq 顺序）切出前 [limit] 行。
ProcessBatchWindow batchProcessRows(List<ProcessRow> rows, int limit) {
  final effective = limit < 0 ? 0 : limit;
  if (rows.length <= effective) {
    return ProcessBatchWindow(
      visible: List<ProcessRow>.unmodifiable(rows),
      hidden: 0,
      total: rows.length,
    );
  }
  return ProcessBatchWindow(
    visible: List<ProcessRow>.unmodifiable(rows.sublist(0, effective)),
    hidden: rows.length - effective,
    total: rows.length,
  );
}

/// 过程组抬头文案：运行中「正在调用工具…」，完成态「N 次工具调用」。
/// **不显示用时**（ADR 0027 §2 的有意简化）。
///
/// 运行态**只由调用方给定的 [running] 决定**（issue #61：= 组内仍有未 settled 的工具
/// 且轮次未结束）。这里不再叠加 `group.running` 二次判定：轮次已结束（aborted/
/// interrupted/error）或工具结果迟到缺失时，组内仍可能残留一条未 settled 的过程行，
/// 但界面不得继续显示「正在调用工具…」。
///
/// [showDetail]（`liveProcessDetail`，标准/详细档）为真时，运行中抬头附带当前工具名；
/// 简洁/完全展开档只显示「正在调用工具…」。该字段只影响抬头文案，**不隐藏过程行**。
String processGroupHeader(
  ProcessGroup group, {
  required bool running,
  bool showDetail = false,
}) {
  if (running) {
    if (showDetail) {
      // 优先当前仍在跑的工具；都已结束但轮次未结束时，用最后一个工具名做细节提示。
      String? name;
      for (final row in group.rows) {
        if (row.isTool && row.running) {
          name = row.toolName;
          break;
        }
      }
      if (name == null || name.isEmpty) {
        for (final row in group.rows) {
          if (row.isTool && row.toolName != null && row.toolName!.isNotEmpty) {
            name = row.toolName;
          }
        }
      }
      if (name != null && name.isNotEmpty) return '正在调用工具…（$name）';
    }
    return '正在调用工具…';
  }
  // issue #75：只有思考、没有工具调用的组不能显示「0 次工具调用」——
  // 那是没有信息量的幽灵抬头，也不符合「组抬头说明该组做了什么」的语义。
  if (group.toolCount == 0) {
    if (group.reasoningChars > 0) {
      return L10n.t(
        '思考 ${group.reasoningChars} 字',
        '${group.reasoningChars} chars of thinking',
      );
    }
    return L10n.t('思考', 'Thinking');
  }
  return L10n.t('${group.toolCount} 次工具调用', '${group.toolCount} tool calls');
}

/// 轮次页脚文案：已完成（可用时带用时）/ 中止 / 中断 / 出错。
String turnFooterText(TurnProcess turn) {
  final kind = turn.endReasonKind;
  final label = switch (kind) {
    'aborted' => '已中止',
    'interrupted' => '已中断',
    'error' => '出错',
    _ => '已完成',
  };
  final duration = turn.durationMs;
  if (duration == null) return label;
  return '$label · 用时 ${formatTurnDuration(duration)}';
}

/// 用时格式：<1s 保留一位小数秒，<60s 保留一位小数秒，<1h 用「分 秒」，否则「小时 分」。
String formatTurnDuration(int milliseconds) {
  final seconds = milliseconds / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} 秒';
  final total = seconds.round();
  if (total < 3600) {
    final minutes = total ~/ 60;
    final rest = total % 60;
    return '$minutes 分 ${rest.toString().padLeft(2, '0')} 秒';
  }
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  return '$hours 小时 ${minutes.toString().padLeft(2, '0')} 分';
}

/// 从服务端事件折叠出的轮次过程跟踪器。
///
/// 只保留**渲染需要的规范值**（seq/callId/step/时间/状态），不保存原始事件，
/// 也不与 [TimelineReducer] 的工具生命周期争抢合并规则——两者各自的职责：
/// 前者回答「这一轮由哪些过程行组成」，后者回答「一次工具调用长什么样」。
class TurnProcessTracker {
  final Map<int, _MutableTurn> _turns = {};
  final Map<int, int> _turnOfStartSeq = {};
  final Map<int, int> _turnOfEndSeq = {};
  final Map<String, _MutableToolRow> _tools = {};
  final Set<int> _reasoningSeqs = {};
  // issue #70：各 (turn, step) 首个 reasoning delta 的 seq（落定后持久行继承排序键）。
  final Map<String, int> _reasoningStarts = {};
  // issue #70（审查 P1）：任何 assistant/message 的落定水位，键同 `_reasoningKey`。
  // 只读查询 [hasSettledReasoning]；用于挡住 reset/reload 后已落定 step 的迟到 chunk。
  final Set<String> _settledAssistantKeys = {};
  final List<int> _humanUserSeqs = [];
  final Set<int> _humanUserSeqSet = {};
  int _order = 0;

  void reset() {
    _turns.clear();
    _turnOfStartSeq.clear();
    _turnOfEndSeq.clear();
    _tools.clear();
    _itemTurn.clear();
    _reasoningSeqs.clear();
    _reasoningStarts.clear();
    _settledAssistantKeys.clear();
    _humanUserSeqs.clear();
    _humanUserSeqSet.clear();
    _order = 0;
  }

  /// issue #70：记录该 (turn, step) 的首个流式 reasoning seq（取最小者）。
  ///
  /// `assistant/message` 落定时持久 reasoning 行的 seq 取
  /// `min(首个 delta seq, message seq)`——与 provisional 行同一排序键，落定不跳位。
  void noteReasoningStart(int turn, int? step, int seq) {
    final key = _reasoningKey(turn, step);
    final prev = _reasoningStarts[key];
    if (prev == null || seq < prev) _reasoningStarts[key] = seq;
  }

  /// 丢弃该轮的全部「首 delta」记录（turn/end / reset / 裁剪时调用，避免悬挂）。
  void dropReasoningStart(int turn) {
    _reasoningStarts.removeWhere((key, _) => key.startsWith('$turn:'));
  }

  static String _reasoningKey(int turn, int? step) => '$turn:${step ?? 'null'}';

  /// 取出并消费该 (turn, step) 的首 delta seq（一条 message 只继承一次）。
  int? _takeReasoningStart(int turn, int? step) =>
      _reasoningStarts.remove(_reasoningKey(turn, step));

  /// issue #70（审查 P1）：该 (turn, step) 是否已有**落定**的 assistant/message 水位。
  ///
  /// 任何 assistant/message（无论是否带 reasoning）都会在 [observe] 登记（O(1) 键集合）；
  /// 实时 chunk 据此做**只读**守卫：reset/reload 回放后，同一 step 的迟到 chunk 不得让
  /// provisional 复活（与持久思考行重复）。键精确匹配——null-step 只代表该轮的无 step
  /// 水位，**不**跨 step 泛化（否则旧历史的无 step message 会误挡后续新 step）。
  bool hasSettledReasoning(int turn, int? step) =>
      _settledAssistantKeys.contains(_reasoningKey(turn, step));

  void _dropSettledAssistant(int turn) {
    _settledAssistantKeys.removeWhere((key) => key.startsWith('$turn:'));
  }

  /// 记录一条事件。可重复调用（历史/实时重叠、分页重叠都是常态）。
  void observe(ChatEvent event) {
    final type = event.type;
    final data = event.data ?? const <String, dynamic>{};
    final seq = event.seq;
    final time = event.time;
    final turn = _intOf(data['turn']);
    final step = _intOf(data['step']);
    // 事件自带 turn 字段时记下 seq → turn，供界面把普通条目（assistant/tool）挂回轮次。
    if (turn != null && seq != null) _itemTurn[seq] = turn;

    switch (type) {
      case 'turn/start':
        if (turn == null || seq == null) return;
        _turnOfStartSeq[seq] = turn;
        final t = _turn(turn);
        t.startSeq = t.startSeq == null ? seq : _min(t.startSeq!, seq);
        if (time != null) {
          t.startedAtMs = t.startedAtMs == null
              ? time
              : _min(t.startedAtMs!, time);
        }
        return;
      case 'turn/end':
        if (turn == null) return;
        final t = _turn(turn);
        if (seq != null) {
          t.endSeq = t.endSeq == null ? seq : _max(t.endSeq!, seq);
          _turnOfEndSeq[seq] = turn;
        }
        t.ended = true;
        final reason = data['reason'];
        if (reason is Map && reason['kind'] is String) {
          t.endReasonKind = reason['kind'] as String;
        }
        if (time != null) {
          t.endedAtMs =
              t.endedAtMs == null ? time : _max(t.endedAtMs!, time);
        }
        return;
      case 'user/message':
        if (seq == null) return;
        final sourceKind = data['sourceKind'];
        final human = sourceKind == null || sourceKind == 'user';
        final text = data['text'] is String ? data['text'] as String : '';
        if (human && !timelineIsInjectedNoise(text)) {
          if (_humanUserSeqSet.add(seq)) _humanUserSeqs.add(seq);
        }
        return;
      case 'assistant/message':
        final reasoning = data['reasoning'] is String
            ? data['reasoning'] as String
            : '';
        // issue #70（审查 P1）：任何 assistant/message 都是该 (turn, step) 的落定水位，
        // **无论是否带 reasoning**（无 reasoning 的 message 同样代表该 step 已推进）。
        // 归属轮次与 reasoning 行同口径；null-step 只登记 null 键，不跨 step 泛化。
        final settledOwner = turn ?? (seq == null ? null : _turnOfSeqNear(seq));
        if (settledOwner != null) {
          _settledAssistantKeys.add(_reasoningKey(settledOwner, step));
        }
        if (reasoning.isNotEmpty && seq != null && _reasoningSeqs.add(seq)) {
          // 历史截断/倒序时可能先看到步骤事件、后看到 turn/start：
          // 归属轮次未知就先跳过（渲染必须有整轮锚点），不落「轮号 0」的假轮次。
          final owner = settledOwner;
          if (owner == null) return;
          final chars = _intOf(data['reasoningChars']) ?? reasoning.length;
          // issue #70：实时路径把首个 delta seq 交给 tracker，持久行继承同一排序键；
          // 历史回放没有 chunk → 无记录 → 行 seq = message seq（外观逐字节不变）。
          final startSeq = _takeReasoningStart(owner, step);
          final rowSeq = startSeq == null ? seq : _min(startSeq, seq);
          _turn(owner).rows.add(_MutableRow(
            seq: rowSeq,
            eventSeq: seq,
            order: _order++,
            step: step,
            kind: ProcessRowKind.reasoning,
            reasoning: reasoning,
            reasoningChars: chars,
          ));
        }
        return;
      case 'tool/call':
        final callId = _callIdOf(data);
        if (callId == null) return;
        final tool = _tool(callId);
        tool.name = _toolNameOf(data, callId, tool.name);
        if (turn != null) tool.turn = turn;
        if (step != null) tool.step = step;
        if (seq != null) {
          tool.reportedSeq = seq;
          _toolOrder(tool);
        }
        return;
      case 'tool/result':
        final callId = _callIdOf(data);
        if (callId == null) return;
        final tool = _tool(callId);
        tool.name = _toolNameOf(data, callId, tool.name);
        if (turn != null) tool.turn = turn;
        if (step != null) tool.step = step;
        tool.settled = true;
        tool.isError = data['isError'] == true;
        if (seq != null && tool.reportedSeq == null) {
          tool.reportedSeq = seq;
          _toolOrder(tool);
        }
        return;
      case 'assistant/chunk':
      case 'assistant/live-chunk':
        if (data['toolCall'] == null && data['argumentsDelta'] == null) return;
        final callId = _callIdOf(data);
        if (callId == null) return;
        final tool = _tool(callId);
        tool.name = _toolNameOf(data, callId, tool.name);
        if (turn != null) tool.turn = turn;
        if (step != null) tool.step = step;
        if (seq != null && tool.reportedSeq == null) {
          tool.reportedSeq = seq;
          _toolOrder(tool);
        }
        return;
      default:
        return;
    }
  }

  /// 事件 seq → 轮次（事件自带 turn 字段的那些）。
  final Map<int, int> _itemTurn = {};

  _MutableTurn _turn(int turn) => _turns.putIfAbsent(turn, () => _MutableTurn(turn));

  _MutableToolRow _tool(String callId) =>
      _tools.putIfAbsent(callId, () => _MutableToolRow(callId));

  void _toolOrder(_MutableToolRow tool) {
    if (tool.order == 0) tool.order = ++_order;
  }

  int? _turnOfSeqNear(int seq) {
    // 无 turn 字段的步骤事件：退回按已登记的起点序号就近归属（历史倒序时常见）。
    int? best;
    var bestStart = -1;
    _turnOfStartSeq.forEach((startSeq, turn) {
      if (startSeq <= seq && startSeq > bestStart) {
        bestStart = startSeq;
        best = turn;
      }
    });
    return best;
  }

  /// 事件 seq 所属的轮次（供界面把普通条目挂到轮次上）。
  int? turnOfSeq(int? seq) {
    if (seq == null) return null;
    final direct = _itemTurn[seq];
    if (direct != null) return direct;
    final byStart = _turnOfStartSeq[seq];
    if (byStart != null) return byStart;
    return _turnOfSeqNear(seq);
  }

  int? turnOfCall(String? callId) =>
      callId == null ? null : _tools[callId]?.turn;

  int? stepOfCall(String? callId) =>
      callId == null ? null : _tools[callId]?.step;

  int? turnOfStartSeq(int seq) => _turnOfStartSeq[seq];

  int? turnOfEndSeq(int seq) => _turnOfEndSeq[seq];

  /// 该轮的首个起点序号（重试边界会有多个 turn/start，过程块只在首个上渲染一次）。
  int? startSeqOfTurn(int turn) => _turns[turn]?.startSeq;

  /// 该轮的末个结束序号（同一轮多次 turn/end 时页脚只渲染一次）。
  int? endSeqOfTurn(int turn) => _turns[turn]?.endSeq;

  /// 已观察到的真人 user 消息 seq（时间无关；用于收起时机与插话判定）。
  List<int> get humanUserSeqs => List<int>.unmodifiable(_humanUserSeqs);

  /// 丢弃早于 [beforeSeq] 的轮次（live 窗口裁剪后调用，避免长时间会话无界增长）。
  void pruneBefore(int beforeSeq) {
    final gone = <int>[];
    _turns.forEach((turn, t) {
      final end = t.endSeq;
      if (end != null && end < beforeSeq) gone.add(turn);
    });
    for (final turn in gone) {
      final t = _turns.remove(turn);
      if (t?.startSeq != null) _turnOfStartSeq.remove(t!.startSeq);
      if (t?.endSeq != null) _turnOfEndSeq.remove(t!.endSeq);
      for (final row in t?.rows ?? const <_MutableRow>[]) {
        _reasoningSeqs.remove(row.eventSeq);
      }
      dropReasoningStart(turn);
      _dropSettledAssistant(turn);
    }
    _reasoningStarts.removeWhere((_, seq) => seq < beforeSeq);
    _tools.removeWhere((_, tool) {
      final seq = tool.reportedSeq;
      if (seq == null) return false; // 还没拿到任何 durable 位置：保留（后续事件会补）
      if (seq < beforeSeq) return true; // 窗口外：无论是哪一轮都裁掉（避免 turn==null 永不回收）
      return tool.turn != null && gone.contains(tool.turn);
    });
    _itemTurn.removeWhere((seq, _) => seq < beforeSeq);
    _humanUserSeqs.removeWhere((seq) => seq < beforeSeq);
    _humanUserSeqSet.removeWhere((seq) => seq < beforeSeq);
  }

  /// 折叠成按 `turn/start` 顺序排列的轮次过程列表。
  List<TurnProcess> build() {
    final result = <TurnProcess>[];
    final turns = _turns.values.where((t) => t.startSeq != null).toList()
      ..sort((a, b) => a.startSeq!.compareTo(b.startSeq!));
    for (final t in turns) {
      // issue #70：同一 (turn, 非空 step) 的带 reasoning 消息只保留 **seq 最大** 的一条
      // （真实内核每 step 一条；此规则只在异常重放/多条 message 时生效，顺序无关）。
      // 缺 step 的行是「整轮一组」的退化形态（ADR 0027 §2），**不得去重**：旧宿主/老历史
      // 常有多条 assistant/message(reasoning) 且无 step，去重会吞掉历史思考（审查 P1-1）。
      final reasoningByStep = <int, _MutableRow>{};
      final reasoningRows = <_MutableRow>[];
      for (final row in t.rows) {
        if (row.kind != ProcessRowKind.reasoning) continue;
        final step = row.step;
        if (step == null) {
          reasoningRows.add(row);
          continue;
        }
        final existing = reasoningByStep[step];
        if (existing == null || row.seq >= existing.seq) {
          reasoningByStep[step] = row;
        }
      }
      reasoningRows.addAll(reasoningByStep.values);
      final rows = <ProcessRow>[
        for (final row in reasoningRows)
          ProcessRow.reasoning(
            seq: row.seq,
            step: row.step,
            reasoning: row.reasoning,
            reasoningChars: row.reasoningChars,
          ),
      ];
      for (final tool in _tools.values) {
        if (tool.turn != t.turn) continue;
        final seq = tool.reportedSeq;
        if (seq == null) continue;
        rows.add(ProcessRow.tool(
          seq: seq,
          step: tool.step,
          callId: tool.callId,
          toolName: tool.name,
          status: tool.settled
              ? (tool.isError ? 'failed' : 'success')
              : 'running',
          isError: tool.isError,
        ));
      }
      rows.sort((a, b) {
        final bySeq = a.seq.compareTo(b.seq);
        if (bySeq != 0) return bySeq;
        return 0;
      });
      // 「轮内有插话」只算**额外的**真人发言：事件序是 turn/start → 提示词 user/message
      // → 过程 → 回答，所以该轮**第一条**真人 user 消息是提示词（不算插话），其余才是插话。
      // 历史分页缺提示词时也按同一规则（不拿「首个过程行之前的 user」去猜——那会把
      // 早到的 steer 误判成提示词，导致本应强制展开的轮被收起）。
      final inRange = <int>[
        for (final seq in _humanUserSeqs)
          if (seq > t.startSeq! && (t.endSeq == null || seq < t.endSeq!)) seq,
      ]..sort();
      final human = inRange.isEmpty
          ? const <int>[]
          : inRange.sublist(1);
      result.add(TurnProcess(
        turn: t.turn,
        startSeq: t.startSeq!,
        endSeq: t.endSeq,
        ended: t.ended,
        endReasonKind: t.endReasonKind,
        startedAtMs: t.startedAtMs,
        endedAtMs: t.endedAtMs,
        groups: _groupRows(rows),
        humanUserSeqs: human,
      ));
    }
    return result;
  }

  List<ProcessGroup> _groupRows(List<ProcessRow> rows) {
    if (rows.isEmpty) return const [];
    final groups = <ProcessGroup>[];
    var current = <ProcessRow>[];
    int? currentStep;
    var started = false;
    void flush() {
      if (current.isEmpty) return;
      groups.add(ProcessGroup(step: currentStep, rows: List.unmodifiable(current)));
    }

    for (final row in rows) {
      if (!started || row.step != currentStep) {
        flush();
        current = <ProcessRow>[row];
        currentStep = row.step;
        started = true;
      } else {
        current.add(row);
      }
    }
    flush();
    return List.unmodifiable(groups);
  }

  static int? _intOf(Object? value) =>
      value is num && value.isFinite ? value.toInt() : null;

  static int _min(int a, int b) => a <= b ? a : b;
  static int _max(int a, int b) => a >= b ? a : b;

  static String? _callIdOf(Map<String, dynamic> data) {
    final id =
        (data['callId'] ?? data['toolCallId'] ?? data['id'])?.toString();
    return id != null && id.isNotEmpty ? id : null;
  }

  static String? _toolNameOf(
    Map<String, dynamic> data,
    String callId,
    String? fallback,
  ) {
    for (final candidate in <Object?>[data['name'], data['toolCall']]) {
      final text = candidate is String ? candidate : candidate?.toString();
      if (text != null && text.isNotEmpty && text != callId) return text;
    }
    return fallback;
  }
}

class _MutableTurn {
  _MutableTurn(this.turn);

  final int turn;
  int? startSeq;
  int? endSeq;
  bool ended = false;
  String? endReasonKind;
  int? startedAtMs;
  int? endedAtMs;
  final List<_MutableRow> rows = [];
}

class _MutableRow {
  _MutableRow({
    required this.seq,
    int? eventSeq,
    required this.order,
    required this.step,
    required this.kind,
    this.reasoning = '',
    this.reasoningChars = 0,
  }) : eventSeq = eventSeq ?? seq;

  /// 渲染排序键（issue #70：落定 reasoning 行可能继承首个 delta seq）。
  final int seq;

  /// 原始事件 seq（`_reasoningSeqs` 去重/裁剪回收用，与 [seq] 可能不同）。
  final int eventSeq;
  final int order;
  final int? step;
  final ProcessRowKind kind;
  final String reasoning;
  final int reasoningChars;
}

class _MutableToolRow {
  _MutableToolRow(this.callId);

  final String callId;
  String? name;
  int? turn;
  int? step;
  int? reportedSeq;
  int order = 0;
  bool settled = false;
  bool isError = false;
}
