// issue #52（ADR 0027 §2）：工作步骤展示模式 / 收起时机设置的持久化测试。
//
// 偏好只存手机本地（SharedPreferences），默认「标准」+「回答结束后」；改动即时写回。

import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/turn_process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStore> makeStore() async {
    final store = AppStore();
    await store.loadPrefs();
    // issue #53（§6.20）：展示模式设置只在服务端声明 turnTail 能力位时显示
    // （旧插件隐藏）；这里模拟新插件契约。
    store.api.turnTailCapabilities = const TurnTailCapabilities(
      version: 1,
      presented: true,
      changed: true,
      changesDiff: true,
    );
    return store;
  }

  Future<void> pumpSettings(WidgetTester tester, AppStore store) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(store: store, onReconfigure: () async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openRow(WidgetTester tester, String title, IconData icon) async {
    await tester.scrollUntilVisible(
      find.byIcon(icon),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(of: find.byIcon(icon), matching: find.byType(InkWell)).first);
    await tester.pumpAndSettle();
    expect(find.text(title), findsWidgets);
  }

  test('默认「标准」+「回答结束后」', () async {
    final store = await makeStore();
    expect(store.stepDisplayMode, WorkStepDisplayMode.standard);
    expect(store.turnFoldTiming, TurnFoldTiming.afterAnswer);
  });

  testWidgets('展示模式四档可选且持久化', (tester) async {
    final store = await makeStore();
    await pumpSettings(tester, store);

    await openRow(tester, '工作步骤展示模式', Icons.tune_outlined);
    await tester.tap(find.text('完全展开').last);
    await tester.pumpAndSettle();
    expect(store.stepDisplayMode, WorkStepDisplayMode.expanded);

    // 重新加载偏好（模拟重启 App）后仍是上次选择。
    final reloaded = await makeStore();
    expect(reloaded.stepDisplayMode, WorkStepDisplayMode.expanded);

    // 再改成「简洁」也应即时生效。
    await pumpSettings(tester, store);
    await openRow(tester, '工作步骤展示模式', Icons.tune_outlined);
    await tester.tap(find.text('简洁').last);
    await tester.pumpAndSettle();
    expect(store.stepDisplayMode, WorkStepDisplayMode.concise);
  });

  testWidgets('收起时机两档可选且持久化', (tester) async {
    final store = await makeStore();
    await pumpSettings(tester, store);

    await openRow(tester, '过程收起时机', Icons.unfold_less_outlined);
    await tester.tap(find.text('下次有新消息时').last);
    await tester.pumpAndSettle();
    expect(store.turnFoldTiming, TurnFoldTiming.onNewMessage);

    final reloaded = await makeStore();
    expect(reloaded.turnFoldTiming, TurnFoldTiming.onNewMessage);
  });

  testWidgets('设置页展示当前档位说明', (tester) async {
    final store = await makeStore()..stepDisplayMode = WorkStepDisplayMode.detailed;
    await pumpSettings(tester, store);

    await tester.scrollUntilVisible(
      find.byIcon(Icons.tune_outlined),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('详细：已完成轮仍折叠'), findsOneWidget);
  });
}
