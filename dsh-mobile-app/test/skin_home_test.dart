// 皮肤首页回归：三套大肥鱼皮肤在手机宽度下不溢出，默认皮肤保持旧首页。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile_app/screens/home_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:dsh_mobile_app/theme.dart';

Future<void> _pumpHome(WidgetTester tester, DshSkin skin) async {
  tester.view.physicalSize = const Size(1170, 2532); // 390 × 844 @3x
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = AppStore()..skin = skin;
  await tester.pumpWidget(MaterialApp(
    theme: DshTheme.forSkin(skin, Brightness.dark),
    home: Scaffold(
      body: HomeScreen(store: store, visible: true, onOpenSession: () {}),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _teardownHome(WidgetTester tester) async {
  // 动态背景用 Timer 推进，换掉页面以取消定时器，避免 pending timer 报错。
  await tester.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('深潜夜航首页渲染且不溢出', (tester) async {
    await _pumpHome(tester, DshSkin.abyss);
    expect(tester.takeException(), isNull);
    expect(find.text('今晚写点什么？'), findsOneWidget);
    await _teardownHome(tester);
  });

  testWidgets('海盐汽水首页渲染且不溢出', (tester) async {
    await _pumpHome(tester, DshSkin.soda);
    expect(tester.takeException(), isNull);
    expect(find.text('把想法丢进汽水里。'), findsOneWidget);
    await _teardownHome(tester);
  });

  testWidgets('鲸落星海首页渲染且不溢出', (tester) async {
    await _pumpHome(tester, DshSkin.whale);
    expect(tester.takeException(), isNull);
    expect(find.text('在星海里，慢慢想。'), findsOneWidget);
    await _teardownHome(tester);
  });

  testWidgets('默认皮肤保持旧首页', (tester) async {
    await _pumpHome(tester, DshSkin.dsh);
    expect(tester.takeException(), isNull);
    expect(find.text('今天打算设计什么？'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    await _teardownHome(tester);
  });
}
