// issue #25 二期：轮次大纲 —— 把宿主的 `turnOutline` 投影与「已加载轮次」合并成
// **完整刻度阶梯**，并为「跳到很久以前某一轮」提供有界的跨页跳转控制流。
//
// 纯 Dart、无 Flutter 依赖（与 `turn_navigation.dart` 同款理由）：合并规则、翻页终止
// 条件与截断呈现都是容易写错、又必须与电脑端一致的部分，必须在没有 widget 树的测试里钉死。
//
// 折叠语义**只有一个来源**（宿主）：本文件不折日志，只消费插件透出的 `turnOutline`。

import 'l10n.dart';
import 'turn_navigation.dart';

/// 宿主轮次大纲里的一轮。
///
/// 形状与电脑端刻度轨消费的 `turnOutline` 投影**完全同形**（每轮：轮次号、该轮
/// `turn/start` 的持久序号、提示词预览、回复预览），因此手机与电脑的轮次边界、
/// 预览文字不会漂移。
class TurnOutlineTurn {
  const TurnOutlineTurn({
    required this.turn,
    required this.seq,
    this.prompt = '',
    this.response = '',
  });

  final int turn;

  /// 该轮起始事件的持久序号——跨页跳转的分页目标语义。
  final int seq;

  final String prompt;
  final String response;

  /// 宽容解析：wire 是外部输入，坏行整条丢弃而不是让整份大纲解析失败。
  static TurnOutlineTurn? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final turn = raw['turn'];
    final seq = raw['seq'];
    if (turn is! int || seq is! int || turn < 0 || seq < 0) return null;
    final prompt = raw['prompt'];
    final response = raw['response'];
    return TurnOutlineTurn(
      turn: turn,
      seq: seq,
      prompt: prompt is String ? prompt : '',
      response: response is String ? response : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TurnOutlineTurn &&
      other.turn == turn &&
      other.seq == seq &&
      other.prompt == prompt &&
      other.response == response;

  @override
  int get hashCode => Object.hash(turn, seq, prompt, response);

  @override
  String toString() => 'TurnOutlineTurn(turn: $turn, seq: $seq)';
}

/// `/turn-outline` 的稳定状态：三态 + 读取失败态。
///
/// 空数组**不得**用来表示"没有轮次"——`capabilityMissing`（宿主没挂这份投影）、
/// `empty`（能力在、这个会话确实没有轮次）、`available` 三者的用户处置完全不同。
enum TurnOutlineState { available, empty, capabilityMissing, readFailed }

/// 一次大纲获取的结果（含截断标记与失败码）。
class TurnOutline {
  const TurnOutline({
    required this.state,
    this.turns = const [],
    this.asOfSeq,
    this.truncated = false,
    this.dropped = 0,
    this.failureCode,
  });

  final TurnOutlineState state;

  /// 按轮次号升序的轮次（`empty` / `capabilityMissing` / `readFailed` 时为空）。
  final List<TurnOutlineTurn> turns;

  /// 投影已知到的持久序号（`-1` 表示空日志），未知时为 null。
  final int? asOfSeq;

  /// 服务端按体积截断过：更早的轮次不在本份大纲里（需上翻）。
  final bool truncated;

  /// 被截断掉的轮次数。
  final int dropped;

  /// `readFailed` 时的稳定失败码（`turn-outline-timeout` 等）。
  final String? failureCode;

  bool get isAvailable => state == TurnOutlineState.available;

  /// 宿主未挂该投影（能力缺失）。
  const TurnOutline.capabilityMissing()
      : state = TurnOutlineState.capabilityMissing,
        turns = const [],
        asOfSeq = null,
        truncated = false,
        dropped = 0,
        failureCode = null;

  /// 读取失败 / 超时：退回一期行为，并保留原因供说明。
  const TurnOutline.readFailed(String code)
      : state = TurnOutlineState.readFailed,
        turns = const [],
        asOfSeq = null,
        truncated = false,
        dropped = 0,
        failureCode = code;

  static TurnOutline fromJson(Map<String, dynamic> json) {
    final state = switch (json['state']) {
      'available' => TurnOutlineState.available,
      'empty' => TurnOutlineState.empty,
      'read-failed' => TurnOutlineState.readFailed,
      _ => TurnOutlineState.capabilityMissing,
    };
    final turns = (json['turns'] as List? ?? const [])
        .map(TurnOutlineTurn.fromJson)
        .whereType<TurnOutlineTurn>()
        .toList()
      ..sort((a, b) => a.turn.compareTo(b.turn));
    final asOfSeq = json['asOfSeq'];
    final dropped = json['dropped'];
    final code = json['code'];
    return TurnOutline(
      state: state,
      turns: turns,
      asOfSeq: asOfSeq is int ? asOfSeq : null,
      truncated: json['truncated'] == true,
      dropped: dropped is int && dropped > 0 ? dropped : 0,
      failureCode: code is String ? code : null,
    );
  }
}

/// 合并后的一齿刻度：已加载轮次与宿主大纲的并集。
class TurnTick {
  const TurnTick({
    required this.turn,
    required this.seq,
    this.prompt = '',
    this.response = '',
    required this.loaded,
  });

  final int turn;
  final int seq;
  final String prompt;
  final String response;

  /// 是否来自**已加载**窗口（未加载的刻度在轨上短而淡，并可触发跨页加载）。
  final bool loaded;

  @override
  bool operator ==(Object other) =>
      other is TurnTick &&
      other.turn == turn &&
      other.seq == seq &&
      other.prompt == prompt &&
      other.response == response &&
      other.loaded == loaded;

  @override
  int get hashCode => Object.hash(turn, seq, prompt, response, loaded);

  @override
  String toString() =>
      'TurnTick(turn: $turn, seq: $seq, loaded: $loaded, prompt: "$prompt")';
}

/// 两路合并成完整刻度集合（按轮次号升序取并集）。
///
/// 规则（issue #25 Implementation Decisions）：
/// - **两边都有时保留已加载锚点**（定位身份仍与一期一致，走 `ensureVisible`）；
/// - 预览**以已加载内容为准**，仅在本地为空时用大纲补齐——这样同一轮在加载前后
///   显示的文字不会跳变（纯图片/纯命令轮的本地提示词为空是常规情况）；
/// - 只在一边的轮次直接通过：只有大纲的轮次以 `loaded: false` 呈现（短淡刻度）。
List<TurnTick> mergeTurnTicks({
  required List<TurnAnchor> loaded,
  required List<TurnOutlineTurn> outline,
}) {
  final byTurn = <int, TurnTick>{};
  for (final remote in outline) {
    byTurn[remote.turn] = TurnTick(
      turn: remote.turn,
      seq: remote.seq,
      prompt: remote.prompt,
      response: remote.response,
      loaded: false,
    );
  }
  for (final anchor in loaded) {
    final remote = byTurn[anchor.turn];
    byTurn[anchor.turn] = TurnTick(
      turn: anchor.turn,
      seq: anchor.seq,
      prompt: anchor.prompt.isEmpty ? (remote?.prompt ?? '') : anchor.prompt,
      response: anchor.response.isEmpty ? (remote?.response ?? '') : anchor.response,
      loaded: true,
    );
  }
  return byTurn.values.toList()..sort((a, b) => a.turn.compareTo(b.turn));
}

/// 跨页跳转的页大小：与电脑端同量级，**不改动**现有上翻的 30 条/页
/// （那是为滚动流畅度调过的，见 issue #25 Implementation Decisions）。
const int kTurnJumpPageSize = 200;

/// 单次跨页跳转的最大页数：有界，避免病态会话把用户无限挂在加载里。
const int kTurnJumpMaxPages = 32;

/// 跨页跳转的最终结果。
enum TurnJumpOutcome {
  /// 目标序号已被加载覆盖，可以定位了。
  covered,

  /// 已到顶端仍不覆盖（历史只剩部分表面 / 序号不连续）：**必须明确告知不可达**。
  unreachable,

  /// 翻页次数达到上限仍未覆盖：同样明确告知，不静默。
  budgetExhausted,

  /// 用户主动滚动等取消了本次跳转。
  cancelled,
}

/// 跨页跳转下一步该做什么（纯决策，便于把终止条件钉死）。
enum TurnJumpAction { done, loadMore, unreachable, outOfBudget }

/// 依据"当前已知的最早序号 / 是否还有更早历史 / 已翻页数"决定下一步。
///
/// [earliestSeq] 为 null 表示当前没有任何已加载内容（尚未拿到历史）。
TurnJumpAction planTurnJump({
  required int targetSeq,
  required int? earliestSeq,
  required bool hasMore,
  required int pagesLoaded,
  int maxPages = kTurnJumpMaxPages,
}) {
  if (earliestSeq != null && earliestSeq <= targetSeq) return TurnJumpAction.done;
  if (!hasMore) return TurnJumpAction.unreachable;
  if (pagesLoaded >= maxPages) return TurnJumpAction.outOfBudget;
  return TurnJumpAction.loadMore;
}

/// 一次翻页后的可观察状态（由页面侧注入，避免本模块依赖 store 或分页实现）。
class TurnPageLoad {
  const TurnPageLoad({this.earliestSeq, required this.hasMore});

  /// 本次翻页后，已加载内容里最早事件的持久序号。
  final int? earliestSeq;

  /// 服务端是否声明还有更早历史。
  final bool hasMore;
}

/// 有界跨页跳转的驱动器。
///
/// 把"逐页向前翻、直到覆盖目标序号"这条控制流抽出来：它是最容易写错的部分
/// （终止条件、用户取消、页数上限），且必须不依赖 Flutter 才能回归。
class TurnPager {
  TurnPager({
    required this.loadOlder,
    required this.snapshot,
    required this.isCancelled,
    this.maxPages = kTurnJumpMaxPages,
  });

  /// 向上翻一页（复用既有历史分页原语），并返回翻页后的可观察状态。
  final Future<TurnPageLoad> Function() loadOlder;

  /// 当前可观察状态（不产生副作用）。
  final TurnPageLoad Function() snapshot;

  /// 用户主动滚动等取消信号。
  final bool Function() isCancelled;

  final int maxPages;

  /// 翻页直到覆盖 [targetSeq]；返回明确结果，**绝不在未覆盖时假装成功**。
  Future<TurnJumpOutcome> jumpTo({required int targetSeq}) async {
    var pages = 0;
    while (true) {
      if (isCancelled()) return TurnJumpOutcome.cancelled;
      final current = snapshot();
      final action = planTurnJump(
        targetSeq: targetSeq,
        earliestSeq: current.earliestSeq,
        hasMore: current.hasMore,
        pagesLoaded: pages,
        maxPages: maxPages,
      );
      switch (action) {
        case TurnJumpAction.done:
          return TurnJumpOutcome.covered;
        case TurnJumpAction.unreachable:
          return TurnJumpOutcome.unreachable;
        case TurnJumpAction.outOfBudget:
          return TurnJumpOutcome.budgetExhausted;
        case TurnJumpAction.loadMore:
          break;
      }
      await loadOlder();
      pages += 1;
    }
  }
}

/// 跨页跳转失败/取消时的用户说明（成功返回 null）。
String? turnJumpOutcomeMessage(TurnJumpOutcome outcome, int turn) {
  switch (outcome) {
    case TurnJumpOutcome.covered:
      return null;
    case TurnJumpOutcome.unreachable:
      return L10n.t(
        '未能跳到第 $turn 轮：历史只剩部分表面，该轮已不可达',
        'Could not jump to turn $turn: it is no longer reachable',
      );
    case TurnJumpOutcome.budgetExhausted:
      return L10n.t(
        '未能跳到第 $turn 轮：已翻到本次跳转的上限，请继续上翻后重试',
        'Could not jump to turn $turn: page budget reached, scroll up and retry',
      );
    case TurnJumpOutcome.cancelled:
      return L10n.t('已取消跳转', 'Jump cancelled');
  }
}

/// 刻度轨上的状态说明（null = 无需说明）。
///
/// 四种情况给出**不同**说明，因为用户该做的事不一样：能力缺失（换电脑端能力）、
/// 该会话暂时没有大纲（等会话进行）、阶梯被截断（更早的轮次要上翻）、
/// 读取失败/超时（退回已加载轮次）。绝不静默。
String? turnOutlineNotice(TurnOutline outline) {
  switch (outline.state) {
    case TurnOutlineState.available:
      if (outline.truncated) {
        return L10n.t(
          '仅显示最近 ${outline.turns.length} 轮：更早的轮次需上翻加载',
          'Showing the latest ${outline.turns.length} turns: scroll up for earlier ones',
        );
      }
      return null;
    case TurnOutlineState.empty:
      return L10n.t('这个会话暂时没有轮次大纲', 'No turn outline for this session yet');
    case TurnOutlineState.capabilityMissing:
      return L10n.t(
        '这台电脑不支持完整轮次阶梯，仅显示已加载轮次',
        'This host has no full turn ladder; showing loaded turns only',
      );
    case TurnOutlineState.readFailed:
      final code = outline.failureCode;
      if (code == 'turn-outline-offline') {
        return L10n.t(
          '当前离线，轮次阶梯暂不可用，仅显示已加载轮次',
          'Offline: the full turn ladder is unavailable; showing loaded turns only',
        );
      }
      if (code == 'turn-outline-timeout' ||
          code == 'turn-outline-client-timeout' ||
          code == 'turn-outline-busy') {
        return L10n.t(
          '轮次大纲重算超时，仅显示已加载轮次',
          'Turn outline recompute timed out; showing loaded turns only',
        );
      }
      return L10n.t(
        '轮次大纲暂时不可用，仅显示已加载轮次',
        'Turn outline unavailable; showing loaded turns only',
      );
  }
}
