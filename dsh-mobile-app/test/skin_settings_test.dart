import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';

void main() {
  testWidgets('设置页外观卡片在手机宽度下不溢出', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppStore()..skin = DshSkin.soda;
    await tester.pumpWidget(MaterialApp(
      theme: DshTheme.forSkin(DshSkin.soda, Brightness.light),
      home: Scaffold(
        body: SettingsScreen(store: store, onReconfigure: () async {}),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.text('主题皮肤'), findsOneWidget);
    expect(find.text('App 图标'), findsOneWidget);
    expect(find.text('海盐汽水'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('浅色模式下点鲸落星海能切换皮肤', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dsh/floating'),
            (call) async => false);
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = AppStore()..skin = DshSkin.dsh;
    await tester.pumpWidget(MaterialApp(
      theme: DshTheme.forSkin(DshSkin.dsh, Brightness.light),
      home: Scaffold(
        body: SettingsScreen(store: store, onReconfigure: () async {}),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('鲸落星海'));
    await tester.pump();
    await tester.tap(find.text('鲸落星海'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
    expect(store.skin, DshSkin.whale);
    await tester.pumpWidget(const SizedBox());
  });
}
