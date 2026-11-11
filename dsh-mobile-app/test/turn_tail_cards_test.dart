// issue #53：轮末两卡的 widget 行为（默认折叠/展开/空态/点击坐标/更多操作）。

import 'package:dsh_mobile_app/turn_tail.dart';
import 'package:dsh_mobile_app/widgets/turn_tail_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

ChangesSummary _summary(int count) => ChangesSummary(
  state: ChangesState.available,
  turn: 2,
  files: [
    for (var index = 0; index < count; index += 1)
      ChangedFile(
        seq: 42,
        index: index,
        display: 'src/f$index.dart',
        name: 'f$index.dart',
        added: index,
        deleted: 1,
      ),
  ],
  total: count,
  added: count,
  deleted: count,
);

void main() {
  testWidgets('改动卡默认收起：只显示前 4 行，展开显示全部、再收起', (tester) async {
    final opened = <int>[];
    await tester.pumpWidget(
      _wrap(
        ChangedFilesCard(
          turn: 2,
          summary: _summary(6),
          onOpenFile: (file) => opened.add(file.index),
          onOpenDiff: (_) {},
        ),
      ),
    );
    expect(find.byKey(TurnTailCardKeys.changedCard), findsOneWidget);
    expect(find.text('本轮改动 6 个文件'), findsOneWidget);
    for (var index = 0; index < 4; index += 1) {
      expect(find.byKey(TurnTailCardKeys.changedRow(index)), findsOneWidget);
    }
    expect(find.byKey(TurnTailCardKeys.changedRow(5)), findsNothing);
    expect(find.text('全部 6 个'), findsOneWidget);

    await tester.tap(find.byKey(TurnTailCardKeys.changedToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(TurnTailCardKeys.changedRow(5)), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(find.byKey(TurnTailCardKeys.changedRow(5)));
    expect(opened, [5]);

    await tester.tap(find.byKey(TurnTailCardKeys.changedToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(TurnTailCardKeys.changedRow(5)), findsNothing);
  });

  testWidgets('改动卡空态不占位；diff 入口回调正确', (tester) async {
    final diffs = <int>[];
    await tester.pumpWidget(
      _wrap(
        ChangedFilesCard(
          turn: 2,
          summary: const ChangesSummary(state: ChangesState.available, turn: 2),
          onOpenFile: (_) {},
          onOpenDiff: diffs.add,
        ),
      ),
    );
    expect(find.byKey(TurnTailCardKeys.changedCard), findsNothing);

    await tester.pumpWidget(
      _wrap(
        ChangedFilesCard(
          turn: 2,
          summary: _summary(2),
          onOpenFile: (_) {},
          onOpenDiff: diffs.add,
        ),
      ),
    );
    await tester.tap(find.byKey(TurnTailCardKeys.changedDiff));
    expect(diffs, [0]);
  });

  testWidgets('交付卡默认收起、>4 收起；行点击与「⋮」回调携带坐标', (tester) async {
    final opened = <int>[];
    final actions = <int>[];
    final files = [
      for (var index = 0; index < 6; index += 1)
        DeliverableFile(
          name: 'out$index.md',
          display: 'docs/out$index.md',
          description: '说明 $index',
          seq: 7,
          index: index,
        ),
    ];
    await tester.pumpWidget(
      _wrap(
        DeliveredFilesCard(
          turn: 2,
          files: files,
          onOpen: (file) => opened.add(file.index),
          onActions: (file) => actions.add(file.index),
        ),
      ),
    );
    expect(find.byKey(TurnTailCardKeys.deliveredCard), findsOneWidget);
    expect(find.text('交付文件 6 个'), findsOneWidget);
    expect(find.byKey(TurnTailCardKeys.deliveredRow(seq: 7, index: 0)), findsOneWidget);
    expect(find.byKey(TurnTailCardKeys.deliveredRow(seq: 7, index: 4)), findsNothing);
    expect(find.text('说明 0'), findsOneWidget);

    await tester.tap(find.byKey(TurnTailCardKeys.deliveredRow(seq: 7, index: 1)));
    expect(opened, [1]);
    await tester.tap(find.byKey(TurnTailCardKeys.deliveredActions(seq: 7, index: 2)));
    expect(actions, [2]);

    await tester.tap(find.byKey(TurnTailCardKeys.deliveredToggle));
    await tester.pumpAndSettle();
    expect(find.byKey(TurnTailCardKeys.deliveredRow(seq: 7, index: 5)), findsOneWidget);
  });

  testWidgets('交付卡空态不占位', (tester) async {
    await tester.pumpWidget(
      _wrap(
        DeliveredFilesCard(
          turn: 2,
          files: const [],
          onOpen: (_) {},
          onActions: (_) {},
        ),
      ),
    );
    expect(find.byKey(TurnTailCardKeys.deliveredCard), findsNothing);
  });

  testWidgets('R09：跨 present 事件同 index 不产生重复兄弟 Key', (tester) async {
    final files = [
      const DeliverableFile(
        name: 'a.md',
        display: 'a.md',
        seq: 10,
        index: 0,
        id: 'id-a',
      ),
      const DeliverableFile(
        name: 'b.md',
        display: 'b.md',
        seq: 20,
        index: 0,
        id: 'id-b',
      ),
    ];
    // 修复前行 Key 都是 -0，debug 构建会抛 Duplicate keys；这里断言正常构建且两行都在。
    await tester.pumpWidget(
      _wrap(
        DeliveredFilesCard(
          turn: 2,
          files: files,
          onOpen: (_) {},
          onActions: (_) {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(TurnTailCardKeys.deliveredRow(seq: 10, index: 0)), findsOneWidget);
    expect(find.byKey(TurnTailCardKeys.deliveredRow(seq: 20, index: 0)), findsOneWidget);
  });
}
