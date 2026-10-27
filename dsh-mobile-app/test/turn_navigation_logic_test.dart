// issue #24：轮次导航的纯逻辑测试（Seam 1）。
//
// 只断言外部可观察行为：给定折叠输入，得到什么轮次索引；给定几何，判定哪个是当前轮。
// 不测私有实现、不依赖 widget 树。

import 'package:dsh_mobile_app/turn_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeTurnPreview', () {
    test('折叠全部空白并去首尾', () {
      expect(normalizeTurnPreview('  第一行\n\n  第二行\t结尾 ', maxChars: 50),
          '第一行 第二行 结尾');
    });

    test('未超长时原样返回，不补省略号', () {
      expect(normalizeTurnPreview('abc', maxChars: 3), 'abc');
    });

    test('超长时按预算截断并补省略号', () {
      final out = normalizeTurnPreview('a' * 60, maxChars: 50);
      expect(out.length, 51); // 50 个字符 + 省略号
      expect(out.endsWith('…'), isTrue);
    });

    test('纯空白归一化为空串（预览回退由展示层决定）', () {
      expect(normalizeTurnPreview('  \n\t ', maxChars: 50), '');
    });
  });

  group('foldTurnAnchors', () {
    test('以 turn/start 为锚，序号即定位锚点', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(boundaryTurn: 1, seq: 5),
        TurnRow(role: TurnRowRole.user, text: '第一个问题'),
        TurnRow(role: TurnRowRole.assistant, text: '第一个回答'),
      ]);
      expect(anchors.length, 1);
      expect(anchors.single.turn, 1);
      expect(anchors.single.seq, 5);
      expect(anchors.single.prompt, '第一个问题');
      expect(anchors.single.response, '第一个回答');
    });

    test('提示词取该轮第一条真人消息（中途引导保留首个预览）', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(boundaryTurn: 1, seq: 5),
        TurnRow(role: TurnRowRole.user, text: '原始问题'),
        TurnRow(role: TurnRowRole.assistant, text: '进行中'),
        TurnRow(role: TurnRowRole.user, text: '中途引导（不该覆盖预览）'),
      ]);
      expect(anchors.single.prompt, '原始问题');
    });

    test('回复取该轮最后一条有文本的助手消息', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(boundaryTurn: 1, seq: 5),
        TurnRow(role: TurnRowRole.user, text: '问'),
        TurnRow(role: TurnRowRole.assistant, text: '先说的'),
        TurnRow(role: TurnRowRole.assistant, text: '最后说的'),
      ]);
      expect(anchors.single.response, '最后说的');
    });

    test('空文本的助手消息不覆盖已有回复', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(boundaryTurn: 1, seq: 5),
        TurnRow(role: TurnRowRole.assistant, text: '有内容'),
        TurnRow(role: TurnRowRole.assistant, text: '   '),
      ]);
      expect(anchors.single.response, '有内容');
    });

    test('边界之前的散落消息不属于任何轮次', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(role: TurnRowRole.user, text: '边界之前'),
        TurnRow(role: TurnRowRole.assistant, text: '也不属于'),
        TurnRow(boundaryTurn: 1, seq: 9),
      ]);
      expect(anchors.single.prompt, '');
      expect(anchors.single.response, '');
    });

    test('未推进轮次号的边界被跳过（重试不产生重复刻度）', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(boundaryTurn: 1, seq: 5),
        TurnRow(role: TurnRowRole.user, text: '问'),
        TurnRow(boundaryTurn: 1, seq: 7), // 同号重试边界
        TurnRow(role: TurnRowRole.assistant, text: '答'),
      ]);
      expect(anchors.length, 1);
      expect(anchors.single.seq, 5, reason: '保留首次边界的序号作为锚点');
      expect(anchors.single.response, '答');
    });

    test('输出按轮次号严格升序', () {
      final anchors = foldTurnAnchors(const [
        TurnRow(boundaryTurn: 3, seq: 30),
        TurnRow(boundaryTurn: 1, seq: 10), // 乱序输入：按到达顺序推进，不允许回退
        TurnRow(boundaryTurn: 4, seq: 40),
      ]);
      final turns = anchors.map((a) => a.turn).toList();
      expect(turns, [3, 4], reason: '轮次号回退的边界被跳过，保持升序');
    });

    test('空输入产出空索引', () {
      expect(foldTurnAnchors(const <TurnRow>[]), isEmpty);
    });

    test('提示词与回复分别按各自预算截断', () {
      final anchors = foldTurnAnchors([
        const TurnRow(boundaryTurn: 1, seq: 5),
        TurnRow(role: TurnRowRole.user, text: 'p' * 80),
        TurnRow(role: TurnRowRole.assistant, text: 'r' * 200),
      ]);
      expect(anchors.single.prompt.length, kTurnPromptMaxChars + 1);
      expect(anchors.single.response.length, kTurnResponseMaxChars + 1);
    });
  });

  group('shouldShowTurnRail', () {
    test('停留在底部时不显形', () {
      expect(shouldShowTurnRail(nearBottom: true, turnCount: 5), isFalse);
    });

    test('上翻且至少 2 轮时显形', () {
      expect(shouldShowTurnRail(nearBottom: false, turnCount: 2), isTrue);
    });

    test('少于 2 轮不显形（一轮没有导航价值）', () {
      expect(shouldShowTurnRail(nearBottom: false, turnCount: 1), isFalse);
      expect(shouldShowTurnRail(nearBottom: false, turnCount: 0), isFalse);
    });
  });

  group('activeTurnFromMounted', () {
    test('取起点不晚于阅读线的最后一个刻度', () {
      final turn = activeTurnFromMounted(
        const [(turn: 1, top: -200.0), (turn: 2, top: 10.0), (turn: 3, top: 300.0)],
        readingLine: 50,
      );
      expect(turn, 2);
    });

    test('阅读线在全部刻度之上时退化为最靠上的刻度', () {
      final turn = activeTurnFromMounted(
        const [(turn: 4, top: 120.0), (turn: 5, top: 200.0)],
        readingLine: 10,
      );
      expect(turn, 4);
    });

    test('没有已构建刻度时返回 null', () {
      expect(activeTurnFromMounted(const [], readingLine: 50), isNull);
    });

    test('几何乱序也能选出正确轮次', () {
      final turn = activeTurnFromMounted(
        const [(turn: 3, top: 300.0), (turn: 1, top: -50.0), (turn: 2, top: 40.0)],
        readingLine: 60,
      );
      expect(turn, 2);
    });
  });

  group('estimateTurnOffset', () {
    test('首尾分别落在可滚动区间两端', () {
      expect(
        estimateTurnOffset(
            targetIndex: 0, childCount: 5, minScrollExtent: 0, maxScrollExtent: 1000),
        0,
      );
      expect(
        estimateTurnOffset(
            targetIndex: 4, childCount: 5, minScrollExtent: 0, maxScrollExtent: 1000),
        1000,
      );
    });

    test('center 锚点下的负最小偏移也被正确映射', () {
      final mid = estimateTurnOffset(
          targetIndex: 0, childCount: 2, minScrollExtent: -300, maxScrollExtent: 700);
      expect(mid, -300);
    });

    test('单条目退化为最大偏移（不可能再分比例）', () {
      expect(
        estimateTurnOffset(
            targetIndex: 0, childCount: 1, minScrollExtent: 0, maxScrollExtent: 500),
        500,
      );
    });

    test('越界序号被夹住，不外推', () {
      expect(
        estimateTurnOffset(
            targetIndex: 99, childCount: 5, minScrollExtent: 0, maxScrollExtent: 1000),
        1000,
      );
    });
  });
}
