// issue #53（§6.20）：旧插件（无 turnTail 能力位）时隐藏「工作步骤展示模式」等设置；
// 新插件声明能力后显示。这是对 M1 设置项的能力位 gating 回归测试。

import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppStore> makeStore({required bool withCapability}) async {
    final store = AppStore();
    await store.loadPrefs();
    store.api.turnTailCapabilities = withCapability
        ? const TurnTailCapabilities(
            version: 1,
            presented: true,
            changed: true,
            changesDiff: true,
          )
        : const TurnTailCapabilities();
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

  testWidgets('旧插件（无能力位）不显示展示模式/收起时机设置', (tester) async {
    final store = await makeStore(withCapability: false);
    await pumpSettings(tester, store);
    await tester.scrollUntilVisible(
      find.text('对话调试模式'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('工作步骤展示模式'), findsNothing);
    expect(find.text('过程收起时机'), findsNothing);
  });

  testWidgets('新插件声明 turnTail 能力位后显示两项设置', (tester) async {
    final store = await makeStore(withCapability: true);
    await pumpSettings(tester, store);
    await tester.scrollUntilVisible(
      find.text('工作步骤展示模式'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('工作步骤展示模式'), findsOneWidget);
    expect(find.text('过程收起时机'), findsOneWidget);
  });
}
