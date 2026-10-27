import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStore> makeStore() async {
    final store = AppStore();
    await store.loadPrefs();
    return store;
  }

  Future<void> openPreferenceDialog(WidgetTester tester, AppStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(store: store, onReconfigure: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gitTabsIcon = find.byIcon(Icons.tab_outlined);
    await tester.scrollUntilVisible(
      gitTabsIcon,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(of: gitTabsIcon, matching: find.byType(InkWell)).first,
    );
    await tester.pumpAndSettle();
  }

  List<String?> displayedGitTabNames(WidgetTester tester) => tester
      .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
      .map((tile) => (tile.title! as Text).data)
      .toList();

  testWidgets('selects one tab and disables removing the last tab', (
    tester,
  ) async {
    final store = await makeStore();
    await openPreferenceDialog(tester, store);

    await tester.tap(find.text('图谱').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作区').last);
    await tester.pumpAndSettle();
    final removeBranches = tester.widget<CheckboxListTile>(
      find
          .ancestor(
            of: find.text('分支').last,
            matching: find.byType(CheckboxListTile),
          )
          .first,
    );
    expect(removeBranches.onChanged, isNull);
    expect(store.gitTabs, ['branches', 'graph', 'worktree']);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.gitTabs, ['branches']);
  });

  testWidgets(
    'reorders tabs, saves, and shows persisted order after reopening',
    (tester) async {
      final store = await makeStore();
      await openPreferenceDialog(tester, store);

      await tester.tap(find.byTooltip('上移 工作区'));
      await tester.pumpAndSettle();
      expect(displayedGitTabNames(tester), [
        '分支',
        '工作区',
        '图谱',
      ], reason: '设置弹窗应立即按已选标签顺序展示');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.gitTabs, ['branches', 'worktree', 'graph']);

      final restored = await makeStore();
      await openPreferenceDialog(tester, restored);
      expect(restored.gitTabs, ['branches', 'worktree', 'graph']);
      expect(find.text('分支 · 工作区 · 图谱'), findsOneWidget);
      expect(displayedGitTabNames(tester), ['分支', '工作区', '图谱']);
      expect(find.byTooltip('上移 工作区'), findsOneWidget);
    },
  );

  testWidgets('reorders tabs down and updates displayed row order', (
    tester,
  ) async {
    final store = await makeStore();
    await openPreferenceDialog(tester, store);

    await tester.tap(find.byTooltip('下移 图谱'));
    await tester.pumpAndSettle();

    expect(displayedGitTabNames(tester), ['分支', '工作区', '图谱']);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.gitTabs, ['branches', 'worktree', 'graph']);
  });

  testWidgets('keeps unselected tabs below selected tabs', (tester) async {
    final store = await makeStore();
    await openPreferenceDialog(tester, store);

    await tester.tap(find.byTooltip('上移 工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('图谱').last);
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    expect(rows.map((tile) => (tile.title! as Text).data).toList(), [
      '分支',
      '工作区',
      '图谱',
    ]);
    expect(rows.last.value, isFalse);
  });
}
