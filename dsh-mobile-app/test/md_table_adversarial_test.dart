import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/md.dart';

/// 表格渲染的维护者对抗性复核（PR #19 / GitLab !3）：
/// 自带测试只覆盖「普通文本 + 一处加粗」，这里补异构内容（行内代码 / 链接 / 中文 /
/// 超长文本）、系统字号缩放、行列数不齐、空表体等场景。
///
/// 两条核心视觉不变量：
/// 1. **同一行所有单元格底边齐平**——否则行分隔线出现断口（阶梯）；
/// 2. **同一列所有单元格 x 起点一致**——否则整表阶梯错位。
/// 断言直接取单元格 Container 的矩形，而不是里面文本的高度（文本自然高度可以不同）。

Future<void> _pump(WidgetTester tester, String md,
    {double width = 320, double scale = 1.0}) async {
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: Builder(
              builder: (context) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: renderMarkdownBlocks(md, context),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
}

/// 单元格 = 有 BoxDecoration 边框、但**没有上边框**的 Container
/// （表格外框用 Border.all，四个边都有值，据此区分）。
bool _isCell(Widget w) {
  if (w is! Container) return false;
  final d = w.decoration;
  if (d is! BoxDecoration) return false;
  final b = d.border;
  return b is Border && b.top == BorderSide.none && b.left == BorderSide.none;
}

List<Rect> _cellRects(WidgetTester tester) => tester
    .widgetList<Container>(find.byWidgetPredicate(_isCell))
    .map((w) => tester.getRect(find.byWidget(w)))
    .toList();

/// 不变量 1：按 top 分组，同组单元格的 bottom 必须完全一致。
void _expectRowsRectangular(WidgetTester tester) {
  final rects = _cellRects(tester);
  expect(rects, isNotEmpty, reason: '没找到任何单元格，断言本身失效');
  final byTop = <double, List<Rect>>{};
  for (final r in rects) {
    byTop.putIfAbsent(r.top, () => <Rect>[]).add(r);
  }
  for (final e in byTop.entries) {
    final bottoms = e.value.map((r) => r.bottom).toSet();
    expect(bottoms.length, 1,
        reason: '同一行单元格底边不齐（行分隔线会断口）：top=${e.key} -> $bottoms');
  }
}

Rect _r(WidgetTester tester, String text) => tester.getRect(find.text(text));

/// 不变量 2：同一列的文本 x 起点一致。
void _expectSameColumnX(WidgetTester tester, List<String> column) {
  final xs = column.map((t) => _r(tester, t).left).toSet();
  expect(xs.length, 1, reason: '同一列 x 起点不一致 → 阶梯错位：$column -> $xs');
}

/// 异构内容：加粗 / 行内代码 / 链接 / 中文 / 数字，宽度与行高差异都很大。
const _hetero = '''
| 键 | 说明 | 示例 |
|---|---|---|
| a | **加粗**说明 | `code_span` |
| bb | [链接](https://example.com/x) | 中文内容 |
| ccc | 普通 | 12345 |
''';

void main() {
  group('表格布局不变量（issue #19 复核）', () {
    testWidgets('A1 异构内容：行矩形化 + 列对齐 + 无字面标记', (tester) async {
      await _pump(tester, _hetero);
      _expectRowsRectangular(tester);
      _expectSameColumnX(tester, ['a', 'bb', 'ccc']);
      _expectSameColumnX(tester, ['加粗说明', '链接', '普通']);
      _expectSameColumnX(tester, ['code_span', '中文内容', '12345']);
      expect(find.textContaining('**'), findsNothing);
      expect(find.textContaining(']('), findsNothing);
    });

    testWidgets('A2 系统字号放大 1.3 倍：行矩形化 + 列对齐（测量与渲染同源）', (tester) async {
      await _pump(tester, _hetero, scale: 1.3);
      _expectRowsRectangular(tester);
      _expectSameColumnX(tester, ['a', 'bb', 'ccc']);
      _expectSameColumnX(tester, ['code_span', '中文内容', '12345']);
    });

    testWidgets('A3 系统字号缩小 0.85 倍：行矩形化 + 列对齐', (tester) async {
      await _pump(tester, _hetero, scale: 0.85);
      _expectRowsRectangular(tester);
      _expectSameColumnX(tester, ['code_span', '中文内容', '12345']);
    });

    testWidgets('A4 超长单元格：不换行（行矩形化）且整表可横向滚动', (tester) async {
      final long = 'x' * 220;
      final md = '| k | v |\n|---|---|\n| short | $long |\n';
      await _pump(tester, md, width: 200);
      _expectRowsRectangular(tester);
      final before = _r(tester, long).left;
      await tester.drag(find.byType(SingleChildScrollView).first, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(_r(tester, long).left, lessThan(before), reason: '超宽表格必须仍能横向滚动');
    });

    testWidgets('A5 行列数不齐（少列 / 多列）不崩溃且列仍对齐', (tester) async {
      const md = '| a | b |\n|---|---|\n| only-one |\n| x | y | 多出来的 |\n';
      await _pump(tester, md, width: 400);
      _expectRowsRectangular(tester);
      _expectSameColumnX(tester, ['a', 'only-one', 'x']);
      _expectSameColumnX(tester, ['b', 'y']);
      expect(find.text('多出来的'), findsOneWidget);
    });

    testWidgets('A6 只有表头没有数据行：不崩溃', (tester) async {
      const md = '| 只有表头 | 第二列 |\n|---|---|\n';
      await _pump(tester, md);
      expect(find.text('只有表头'), findsOneWidget);
      expect(find.text('第二列'), findsOneWidget);
      _expectRowsRectangular(tester);
    });

    testWidgets('A7 单元格内联代码比普通文本宽时，列宽取最大值', (tester) async {
      const md = '| 类型 | 值 |\n|---|---|\n'
          '| 短 | `a_very_long_inline_code_token` |\n'
          '| 长一些的 | `x` |\n';
      await _pump(tester, md, width: 300);
      _expectRowsRectangular(tester);
      _expectSameColumnX(tester, ['短', '长一些的']);
      _expectSameColumnX(tester, ['a_very_long_inline_code_token', 'x']);
    });

    testWidgets('A8 单元格含链接：不崩溃且不显示字面标记（WidgetSpan 测量兜底）', (tester) async {
      const md = '| 名称 | 链接 |\n|---|---|\n'
          '| 短 | [文档](https://example.com/doc) |\n'
          '| 长一些的 | 纯文本 |\n';
      await _pump(tester, md, width: 320);
      expect(find.text('文档'), findsOneWidget);
      expect(find.textContaining(']('), findsNothing);
      _expectRowsRectangular(tester);
      _expectSameColumnX(tester, ['短', '长一些的']);
    });
  });
}
