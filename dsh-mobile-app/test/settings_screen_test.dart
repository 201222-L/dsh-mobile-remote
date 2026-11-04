import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';
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
        '文件历史',
      ], reason: '设置弹窗应立即按已选标签顺序展示');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(store.gitTabs, ['branches', 'worktree', 'graph']);

      final restored = await makeStore();
      await openPreferenceDialog(tester, restored);
      expect(restored.gitTabs, ['branches', 'worktree', 'graph']);
      expect(find.text('分支 · 工作区 · 图谱'), findsOneWidget);
      expect(displayedGitTabNames(tester), ['分支', '工作区', '图谱', '文件历史']);
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

    expect(displayedGitTabNames(tester), ['分支', '工作区', '图谱', '文件历史']);
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
      '文件历史',
    ]);
    expect(rows.last.value, isFalse);
  });

  testWidgets('offers four git tab candidates while still capping at three', (
    tester,
  ) async {
    final store = await makeStore();
    await openPreferenceDialog(tester, store);

    expect(displayedGitTabNames(tester), ['分支', '图谱', '工作区', '文件历史']);
    // 旧宿主没有该能力时 tab 降级为不可用提示，弹窗里需给出说明（US16）。
    expect(find.byKey(const Key('git-tabs-file-history-note')), findsOneWidget);
    final rows = tester
        .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
        .toList();
    // 已选满 3 个时，未选的第四项不可勾选（维持 1–3 规则）。
    expect(rows.last.value, isFalse);
    expect(rows.last.onChanged, isNull);

    // 取消一个、勾选「文件历史」，仍是最多 3 个且默认顺序不变。
    await tester.tap(find.text('图谱').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.gitTabs, ['branches', 'worktree', 'fileHistory']);
  });

  testWidgets('文件浏览 → 显示隐藏文件开关默认开、可切换并持久化', (tester) async {
    final store = await makeStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(store: store, onReconfigure: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rowText = find.text('显示隐藏文件');
    await tester.scrollUntilVisible(
      rowText,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(store.showHiddenFiles, isTrue);

    final toggle = find.descendant(
      of: find.ancestor(of: rowText, matching: find.byType(InkWell)).first,
      matching: find.byType(DshSwitch),
    );
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(store.showHiddenFiles, isFalse);

    // 持久化：新 store 加载后仍为关闭。
    final restored = await makeStore();
    expect(restored.showHiddenFiles, isFalse);

    // 再切回开启。
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(store.showHiddenFiles, isTrue);
  });
}
