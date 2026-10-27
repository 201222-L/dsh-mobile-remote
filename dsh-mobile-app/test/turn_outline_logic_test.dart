// issue #25 二期：轮次大纲与跨页跳转的纯逻辑测试（Seam 2）。
//
// 只断言外部可观察行为：给定两路输入得到什么刻度集合；给定可观察状态与终止条件，
// 跳转的最终结果是什么、说明文字是什么。不测私有实现、不依赖 widget 树。

import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/turn_navigation.dart';
import 'package:dsh_mobile_app/turn_outline.dart';
import 'package:flutter_test/flutter_test.dart';

TurnAnchor anchor(int turn, int seq, {String prompt = '', String response = ''}) =>
    TurnAnchor(turn: turn, seq: seq, prompt: prompt, response: response);

TurnOutlineTurn remote(int turn, int seq, {String prompt = '', String response = ''}) =>
    TurnOutlineTurn(turn: turn, seq: seq, prompt: prompt, response: response);

void main() {
  setUp(() => L10n.lang = 'zh');

  group('TurnOutline.fromJson', () {
    test('可用态解析轮次并保证升序', () {
      final outline = TurnOutline.fromJson({
        'ok': true,
        'state': 'available',
        'asOfSeq': 40,
        'turns': [
          {'turn': 3, 'seq': 40, 'prompt': 'c', 'response': ''},
          {'turn': 1, 'seq': 0, 'prompt': 'a', 'response': 'b'},
        ],
      });
      expect(outline.state, TurnOutlineState.available);
      expect(outline.turns.map((t) => t.turn).toList(), [1, 3]);
      expect(outline.asOfSeq, 40);
      expect(outline.truncated, isFalse);
    });

    test('三态互不相同，且空数组不表示没有轮次', () {
      expect(TurnOutline.fromJson({'state': 'empty', 'turns': []}).state,
          TurnOutlineState.empty);
      expect(TurnOutline.fromJson({'state': 'capability-missing'}).state,
          TurnOutlineState.capabilityMissing);
      final failed = TurnOutline.fromJson({
        'state': 'read-failed',
        'code': 'turn-outline-timeout',
        'degraded': true,
      });
      expect(failed.state, TurnOutlineState.readFailed);
      expect(failed.failureCode, 'turn-outline-timeout');
    });

    test('未知 state 归为能力缺失（不误报成"没有轮次"）', () {
      expect(TurnOutline.fromJson({'state': 'future-state'}).state,
          TurnOutlineState.capabilityMissing);
    });

    test('截断标记与丢弃数被保留', () {
      final outline = TurnOutline.fromJson({
        'state': 'available',
        'truncated': true,
        'dropped': 3820,
        'turns': [
          {'turn': 3821, 'seq': 1},
        ],
      });
      expect(outline.truncated, isTrue);
      expect(outline.dropped, 3820);
    });

    test('坏行整条丢弃，不拖垮整份大纲', () {
      final outline = TurnOutline.fromJson({
        'state': 'available',
        'turns': [
          {'turn': 1, 'seq': 0},
          {'turn': 'x', 'seq': 3},
          {'turn': 2},
          'not-a-map',
          {'turn': 3, 'seq': 12, 'prompt': 42},
        ],
      });
      expect(outline.turns.map((t) => t.turn).toList(), [1, 3]);
      expect(outline.turns[1].prompt, '');
    });
  });

  group('mergeTurnTicks', () {
    test('两路按轮次号取并集并升序', () {
      final ticks = mergeTurnTicks(
        loaded: [anchor(2, 12, prompt: '本地的二'), anchor(3, 40)],
        outline: [remote(1, 0, prompt: '远处的第一轮'), remote(2, 12, prompt: '大纲的二')],
      );
      expect(ticks.map((t) => t.turn).toList(), [1, 2, 3]);
      expect(ticks.map((t) => t.loaded).toList(), [false, true, true]);
    });

    test('两边都有时保留已加载锚点（seq 以已加载为准）', () {
      final ticks = mergeTurnTicks(
        loaded: [anchor(2, 99, prompt: '本地')],
        outline: [remote(2, 12, prompt: '大纲')],
      );
      expect(ticks.single.seq, 99);
      expect(ticks.single.loaded, isTrue);
    });

    test('预览以已加载为准，仅本地为空时用大纲补齐（加载前后不跳变）', () {
      final ticks = mergeTurnTicks(
        loaded: [
          anchor(2, 12, prompt: '', response: '本地回复'),
        ],
        outline: [remote(2, 12, prompt: '大纲提示', response: '大纲回复')],
      );
      expect(ticks.single.prompt, '大纲提示');
      expect(ticks.single.response, '本地回复');
    });

    test('只有大纲的轮次以未加载刻度通过', () {
      final ticks = mergeTurnTicks(
        loaded: const [],
        outline: [remote(7, 300, prompt: '很久以前')],
      );
      expect(ticks.single.loaded, isFalse);
      expect(ticks.single.seq, 300);
    });

    test('两路都空时得到空刻度（由显隐判据决定不渲染）', () {
      expect(mergeTurnTicks(loaded: const [], outline: const []), isEmpty);
      expect(
        shouldShowTurnRail(nearBottom: false, turnCount: 0),
        isFalse,
      );
    });
  });

  group('planTurnJump', () {
    test('目标序号已被覆盖即完成', () {
      expect(
        planTurnJump(targetSeq: 100, earliestSeq: 100, hasMore: true, pagesLoaded: 0),
        TurnJumpAction.done,
      );
      expect(
        planTurnJump(targetSeq: 100, earliestSeq: 40, hasMore: true, pagesLoaded: 0),
        TurnJumpAction.done,
      );
    });

    test('还需要更早历史时继续翻页', () {
      expect(
        planTurnJump(targetSeq: 10, earliestSeq: 900, hasMore: true, pagesLoaded: 0),
        TurnJumpAction.loadMore,
      );
    });

    test('没有更早历史 → 不可达（明确告知，不静默停）', () {
      expect(
        planTurnJump(targetSeq: 10, earliestSeq: 900, hasMore: false, pagesLoaded: 0),
        TurnJumpAction.unreachable,
      );
    });

    test('翻页次数到上限 → 超出预算', () {
      expect(
        planTurnJump(
          targetSeq: 10,
          earliestSeq: 900,
          hasMore: true,
          pagesLoaded: 3,
          maxPages: 3,
        ),
        TurnJumpAction.outOfBudget,
      );
    });

    test('一次都没加载（earliestSeq 为 null）且没有更早历史 → 不可达', () {
      expect(
        planTurnJump(targetSeq: 0, earliestSeq: null, hasMore: false, pagesLoaded: 0),
        TurnJumpAction.unreachable,
      );
    });
  });

  group('TurnPager', () {
    /// 造一个"每次上翻一页、已知最早序号按 [pageEarliestSeqs] 递减"的假会话。
    /// 第一项是翻页前就已加载的最早序号；翻到末项后由 [hasMore] 决定是否还有更早历史。
    ({TurnPager pager, List<int> loads}) buildPager({
      required List<int> pageEarliestSeqs,
      required bool hasMore,
      int maxPages = kTurnJumpMaxPages,
      bool Function()? isCancelled,
    }) {
      final loads = <int>[];
      var earliest = pageEarliestSeqs.first;
      var more = true;
      final pager = TurnPager(
        loadOlder: () async {
          loads.add(earliest);
          final nextIndex = loads.length;
          earliest = pageEarliestSeqs[nextIndex.clamp(0, pageEarliestSeqs.length - 1)];
          more = nextIndex < pageEarliestSeqs.length - 1 || hasMore;
          return TurnPageLoad(earliestSeq: earliest, hasMore: more);
        },
        snapshot: () => TurnPageLoad(earliestSeq: earliest, hasMore: more),
        isCancelled: isCancelled ?? () => false,
        maxPages: maxPages,
      );
      return (pager: pager, loads: loads);
    }

    test('逐页翻到覆盖目标序号后停下', () async {
      final built = buildPager(
        pageEarliestSeqs: [1000, 800, 600, 400, 200, 50],
        hasMore: true,
      );
      // 初始 earliest=1000，目标 500：翻到 400 那一页即覆盖。
      final outcome = await built.pager.jumpTo(targetSeq: 500);
      expect(outcome, TurnJumpOutcome.covered);
      expect(built.loads.length, 3);
    });

    test('到达顶端仍不覆盖 → unreachable（不假装成功）', () async {
      final built = buildPager(
        pageEarliestSeqs: [1000, 800],
        hasMore: false,
      );
      final outcome = await built.pager.jumpTo(targetSeq: 10);
      expect(outcome, TurnJumpOutcome.unreachable);
      expect(turnJumpOutcomeMessage(outcome, 1), contains('不可达'));
    });

    test('翻页到上限 → budgetExhausted，说明里指向"继续上翻后重试"', () async {
      final built = buildPager(
        pageEarliestSeqs: List.generate(50, (i) => 100000 - i * 100),
        hasMore: true,
        maxPages: 3,
      );
      final outcome = await built.pager.jumpTo(targetSeq: 5);
      expect(outcome, TurnJumpOutcome.budgetExhausted);
      expect(built.loads.length, 3);
      expect(turnJumpOutcomeMessage(outcome, 9), contains('继续上翻'));
    });

    test('用户主动滚动取消 → 立即停止且不再翻页', () async {
      var loads = 0;
      final pager = TurnPager(
        loadOlder: () async {
          loads += 1;
          return const TurnPageLoad(earliestSeq: 900, hasMore: true);
        },
        snapshot: () => const TurnPageLoad(earliestSeq: 900, hasMore: true),
        // 翻过一页后用户开始滚动：跳转必须立刻放弃，而不是继续翻到上限。
        isCancelled: () => loads >= 1,
      );
      final outcome = await pager.jumpTo(targetSeq: 10);
      expect(outcome, TurnJumpOutcome.cancelled);
      expect(loads, 1);
      expect(turnJumpOutcomeMessage(outcome, 10), '已取消跳转');
    });

    test('成功时不产生任何说明（只有失败/取消才说明）', () {
      expect(turnJumpOutcomeMessage(TurnJumpOutcome.covered, 3), isNull);
    });
  });

  group('turnOutlineNotice', () {
    test('可用且未截断时无需说明', () {
      final outline = TurnOutline.fromJson({
        'state': 'available',
        'turns': [
          {'turn': 1, 'seq': 0},
        ],
      });
      expect(turnOutlineNotice(outline), isNull);
    });

    test('截断时明确告知更早轮次需上翻', () {
      final outline = TurnOutline.fromJson({
        'state': 'available',
        'truncated': true,
        'dropped': 3800,
        'turns': List.generate(3, (i) => {'turn': i + 1, 'seq': i}),
      });
      expect(turnOutlineNotice(outline), contains('上翻'));
    });

    test('能力缺失与该会话无大纲给出不同说明', () {
      final missing = turnOutlineNotice(const TurnOutline.capabilityMissing())!;
      final empty = turnOutlineNotice(
        const TurnOutline(state: TurnOutlineState.empty),
      )!;
      expect(missing, isNot(empty));
      expect(missing, contains('这台电脑'));
      expect(empty, contains('这个会话'));
    });

    test('超时与其它读取失败给出不同说明', () {
      final timeout = turnOutlineNotice(const TurnOutline.readFailed('turn-outline-timeout'))!;
      final other = turnOutlineNotice(const TurnOutline.readFailed('session-corrupt'))!;
      expect(timeout, isNot(other));
      expect(timeout, contains('超时'));
      expect(other, contains('不可用'));
    });
  });
}
