// issue #33：宽表格在**真实树**里必须赢得横向手势，
// 而不是被外层纵向消息列表抢走后一路"上翻历史"。
//
// 缺陷机制（源码级定位 + 本文件实测，flutter 3.47）：表格的横向
// `SingleChildScrollView` 与外层纵向消息列表在同一个手势竞技场竞争，两者都从环境
// `MediaQuery.gestureSettings` 取拖拽阈值（Android 实测 ≈8px，测试环境 18px）。
// 首次移动事件纵向分量先越线、横向分量尚未越线时，**只有纵向识别器**被接受 →
// 纵向列表赢下整个手势：表格完全滑不动（用户"无法顺畅地左右滚动"），列表跟着手指
// 上翻，并因靠近前缘触发 shouldLoadOlderFromScroll → _loadMoreInfinite()
// （每页 30 条、可无限重复）→ 用户被带到任意早的历史位置。
//
// 既有 md_table_test.dart / md_table_adversarial_test.dart 把表格放进裸 Scaffold、
// 外层没有任何可滚动控件，表格永远赢 —— 这正是该缺陷长期被漏掉的原因。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/md.dart';

/// 明显超宽的表格：6 列长内容，保证表格横向 maxScrollExtent > 0。
const _wideTable = '''
| 列一 | 列二 | 列三 | 列四 | 列五 | 列六 |
|---|---|---|---|---|---|
| AAAAAAAAAAAAAAAA | BBBBBBBBBBBBBBBB | CCCCCCCCCCCCCCCC | DDDDDDDDDDDDDDDD | EEEEEEEEEEEEEEEE | FFFFFFFFFFFFFFFF |
| GGGGGGGGGGGGGGGG | HHHHHHHHHHHHHHHH | IIIIIIIIIIIIIIII | JJJJJJJJJJJJJJJJ | KKKKKKKKKKKKKKKK | LLLLLLLLLLLLLLLL |
''';

const _cellA = 'AAAAAAAAAAAAAAAA';

/// 复刻 chat_screen.dart 的真实层级：SelectionArea → 纵向 ListView → 表格。
Future<void> _pumpRealTree(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SelectionArea(
          child: ListView(
            children: [
              const SizedBox(height: 600),
              Builder(
                builder: (context) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: renderMarkdownBlocks(_wideTable, context),
                ),
              ),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    ),
  );
  // 列表停在中间：这样"手指向下拖"有空间向上滚动，才能观察到列表是否被抢走。
  _pixels(tester, Axis.vertical, jumpTo: 300);
  await tester.pumpAndSettle();
}

/// 取某个轴向可滚动控件的偏移。
/// 本树里 `find.byType(Scrollable)` 只匹配到外层消息列表，表格自身那个要经
/// `SingleChildScrollView` 的后代查找才拿得到（已用调试用例实测确认）。
double _pixels(WidgetTester tester, Axis axis, {double? jumpTo}) {
  final finder = axis == Axis.vertical
      ? find.byType(Scrollable)
      : find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        );
  final position = tester.state<ScrollableState>(finder.first).position;
  if (jumpTo != null) position.jumpTo(jumpTo);
  return position.pixels;
}

void main() {
  testWidgets('宽表格：起始略偏纵向的横滑由表格横向滚动，消息列表不动（issue #33）', (tester) async {
    await _pumpRealTree(tester);
    final outerBefore = _pixels(tester, Axis.vertical);
    final innerBefore = _pixels(tester, Axis.horizontal);
    expect(innerBefore, 0.0, reason: '表格初始应停在最左');

    final g = await tester.startGesture(tester.getCenter(find.text(_cellA)));
    // 真机形态的首次移动：纵向分量先越线（dy=20 > 阈值），横向分量已明显
    // （dx=12，dx/dy=0.6 —— 在真机 ≈8px 阈值下同样属于"该归表格"的手势）。
    // 修复前只有纵向识别器越线 → 列表赢下整个手势，后续纯横向移动对它毫无作用。
    await g.moveBy(const Offset(12, 20));
    await tester.pump();
    await g.moveBy(const Offset(-40, 0));
    await tester.pump();
    await g.moveBy(const Offset(-40, 0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(
      _pixels(tester, Axis.horizontal) - innerBefore,
      greaterThan(0),
      reason: '表格应当横向滚动（修复前恒为 0：完全滑不动）',
    );
    expect(
      _pixels(tester, Axis.vertical),
      outerBefore,
      reason: '外层消息列表不应被拖动 → 不应上翻历史、不应触发"加载更早"',
    );
  });

  testWidgets('宽表格：纯纵向拖动仍归消息列表，表格不越权抢占', (tester) async {
    await _pumpRealTree(tester);
    final outerBefore = _pixels(tester, Axis.vertical);
    final innerBefore = _pixels(tester, Axis.horizontal);

    final g = await tester.startGesture(tester.getCenter(find.text(_cellA)));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();

    expect(
      _pixels(tester, Axis.vertical),
      lessThan(outerBefore),
      reason: '纯纵向手势应当滚动消息列表',
    );
    expect(
      _pixels(tester, Axis.horizontal),
      innerBefore,
      reason: '横向分量为 0 时表格不应抢占手势',
    );
  });
}
