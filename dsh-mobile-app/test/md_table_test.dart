import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_mobile_app/md.dart';

/// 表格渲染回归（GitLab !3）：
/// 此前每行是独立 Row、单元格各取自然宽 → 同一列跨行错位数百像素、边框阶梯断框；
/// 且单元格用裸 Text，`**加粗**` / `` `代码` `` 的标记原样可见。
const _table = '''
| 名称 | 值 | 备注 |
|---|---|---|
| alpha | 1 | **加粗**内容 |
| beta-long | 22 | 普通 |
| gamma | 333 | 普通 |
''';

Future<void> _pump(WidgetTester tester, String md, {double width = 320}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
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
  ));
}

double _left(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dx;

void main() {
  testWidgets('共享列宽：同一列的 x 起点跨行一致，且行高统一（不换行）', (tester) async {
    await _pump(tester, _table);
    expect(_left(tester, '1'), _left(tester, '22'));
    expect(_left(tester, '22'), _left(tester, '333'));
    expect(_left(tester, 'alpha'), _left(tester, 'beta-long'));
    expect(_left(tester, 'beta-long'), _left(tester, 'gamma'));
    expect(tester.getSize(find.text('alpha')).height, tester.getSize(find.text('333')).height);
  });

  testWidgets('单元格解析行内 Markdown：不出现字面标记', (tester) async {
    await _pump(tester, _table);
    expect(find.textContaining('**'), findsNothing);
    expect(find.text('加粗内容'), findsOneWidget);
  });

  testWidgets('超宽表格仍可横向滚动', (tester) async {
    await _pump(tester, _table, width: 120);
    final before = _left(tester, '333');
    await tester.drag(find.byType(SingleChildScrollView).first, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(_left(tester, '333'), lessThan(before));
  });
}
