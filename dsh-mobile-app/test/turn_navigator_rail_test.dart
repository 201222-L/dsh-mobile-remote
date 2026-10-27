// issue #24：刻度轨的交互测试（Seam 2）。
//
// 只断言用户可观察的行为：什么时候出现、点按跳到哪里、长按扫掠看到什么、松手落在哪。
// 不测私有方法、不锁死 widget 树形状。

import 'package:dsh_mobile_app/turn_navigation.dart';
import 'package:dsh_mobile_app/widgets/turn_navigator_rail.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<TurnAnchor> anchorsOf(List<(int turn, String prompt, String response)> rows) =>
    [
      for (final (turn, prompt, response) in rows)
        TurnAnchor(turn: turn, seq: turn * 10, prompt: prompt, response: response),
    ];

Future<void> pumpRail(
  WidgetTester tester, {
  required List<TurnAnchor> anchors,
  int? activeTurn,
  int? busyTurn,
  void Function(TurnAnchor)? onNavigate,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: TurnNavigatorRail(
          anchors: anchors,
          activeTurn: activeTurn,
          busyTurn: busyTurn,
          onNavigate: onNavigate ?? (_) {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('显隐', () {
    testWidgets('少于 2 轮时完全不渲染（一轮没有导航价值）', (tester) async {
      await pumpRail(tester, anchors: anchorsOf([(1, '只有一轮', '答')]));
      expect(tester.getSize(find.byType(TurnNavigatorRail)), Size.zero);
    });

    testWidgets('0 轮时不渲染', (tester) async {
      await pumpRail(tester, anchors: anchorsOf([]));
      expect(tester.getSize(find.byType(TurnNavigatorRail)), Size.zero);
    });

    testWidgets('至少 2 轮时渲染出刻度轨', (tester) async {
      await pumpRail(tester, anchors: anchorsOf([(1, '一', 'a'), (2, '二', 'b')]));
      final size = tester.getSize(find.byType(TurnNavigatorRail));
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
      expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('turn-tick-2')), findsOneWidget);
    });

    testWidgets('每个已知轮次各有一个刻度', (tester) async {
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, 'a', ''), (2, 'b', ''), (3, 'c', '')]),
      );
      expect(find.byKey(const ValueKey<String>('turn-tick-1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('turn-tick-2')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('turn-tick-3')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('turn-tick-4')), findsNothing);
    });
  });

  group('点按 = 直接跳转', () {
    testWidgets('点某个刻度会用对应的轮次回调', (tester) async {
      TurnAnchor? navigated;
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, '一', 'a'), (2, '二', 'b'), (3, '三', 'c')]),
        onNavigate: (a) => navigated = a,
      );
      // 刻度轨在手势上是一个整体：帧级 GestureDetector 统一处理点按与长按扫掠，
      // 因此命中的是父级而不是刻度自身——这里关掉"未命中"告警（行为正确）。
      await tester.tap(
        find.byKey(const ValueKey<String>('turn-tick-2')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(navigated?.turn, 2);
      expect(navigated?.seq, 20);
    });
  });

  group('长按扫掠 = 预览 + 松手落点', () {
    testWidgets('长按浮出预览，显示提示词与回复', (tester) async {
      await pumpRail(
        tester,
        anchors: anchorsOf([
          (1, '第一个问题', '第一个回答'),
          (2, '第二个问题', '第二个回答'),
        ]),
      );
      final tick = tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-2')));
      final gesture = await tester.startGesture(tick);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.text('第二个问题'), findsOneWidget);
      expect(find.text('第二个回答'), findsOneWidget);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('松手落在预览所指的那一轮', (tester) async {
      TurnAnchor? navigated;
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, '一', 'a'), (2, '二', 'b'), (3, '三', 'c')]),
        onNavigate: (a) => navigated = a,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-1'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      // 沿轨向下拖到第 3 轮
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-3'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(navigated?.turn, 3, reason: '松手落在拖动结束时所指的轮次');
    });

    testWidgets('长按取消（手势被抢走）不落点', (tester) async {
      TurnAnchor? navigated;
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, '一', 'a'), (2, '二', 'b')]),
        onNavigate: (a) => navigated = a,
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-1'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.cancel();
      await tester.pump();
      expect(navigated, isNull);
    });
  });

  group('预览内容', () {
    testWidgets('提示词为空（纯图片/纯命令轮）时回退为「第 N 轮」', (tester) async {
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, '', '只有回复'), (2, '有提示词', '')]),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-1'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.text('第 1 轮'), findsOneWidget);
      expect(find.text('只有回复'), findsOneWidget);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('回复为空时不渲染回复行', (tester) async {
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, '只有提示词', ''), (2, 'x', 'y')]),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('turn-tick-1'))),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pump();

      expect(find.text('只有提示词'), findsOneWidget);
      expect(find.text(''), findsNothing);

      await gesture.up();
      await tester.pump();
    });
  });

  group('当前轮与跳转中', () {
    testWidgets('跳转中的刻度能正常渲染（脉冲不崩）', (tester) async {
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, 'a', ''), (2, 'b', '')]),
        busyTurn: 2,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey<String>('turn-tick-2')), findsOneWidget);
    });

    testWidgets('当前轮高亮不影响其它刻度的存在', (tester) async {
      await pumpRail(
        tester,
        anchors: anchorsOf([(1, 'a', ''), (2, 'b', ''), (3, 'c', '')]),
        activeTurn: 2,
      );
      for (final turn in [1, 2, 3]) {
        expect(find.byKey(ValueKey<String>('turn-tick-$turn')), findsOneWidget);
      }
    });
  });

  // issue #25 二期：未加载轮次以**短而淡**的刻度区分于已加载轮次——把这条视觉契约
  // 抽成纯函数后就能钉死，而不是只靠肉眼看 build。
  group('未加载刻度的视觉权重', () {
    test('未加载刻度比已加载刻度更短', () {
      expect(
        turnTickScale(active: false, previewed: false, unloaded: true),
        lessThan(turnTickScale(active: false, previewed: false, unloaded: false)),
      );
    });

    test('未加载刻度比已加载刻度更淡', () {
      expect(
        turnTickAlpha(unloaded: true),
        lessThan(turnTickAlpha(unloaded: false)),
      );
    });

    test('当前轮与预览态优先级更高（不受未加载标记影响）', () {
      expect(turnTickScale(active: true, previewed: false, unloaded: true), 1.0);
      expect(turnTickScale(active: false, previewed: true, unloaded: true), 0.9);
    });
  });

  // issue #24 评审 note 1054 缺陷 2：100 刻度时被裁出的刻度必须能浏览。
  group('缺陷 2：超长刻度轨可浏览被裁出的刻度', () {
    List<TurnAnchor> anchors100() =>
        [for (var i = 1; i <= 100; i++) TurnAnchor(turn: i, seq: i * 10)];

    Future<void> pumpRail(WidgetTester tester, {required int activeTurn}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: TurnNavigatorRail(
              anchors: anchors100(),
              activeTurn: activeTurn,
              busyTurn: null,
              onNavigate: (_) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('初次显示时当前轮（90）在轨内可见，首个刻度不在', (tester) async {
      await pumpRail(tester, activeTurn: 90);
      final railRect = tester.getRect(find.byType(TurnNavigatorRail));
      final tick90 = tester.getRect(find.byKey(const ValueKey('turn-tick-90')));
      final tick1 = tester.getRect(find.byKey(const ValueKey('turn-tick-1')));
      expect(railRect.overlaps(tick90), isTrue, reason: '初次布局就要保证当前轮可见');
      expect(railRect.overlaps(tick1), isFalse, reason: '首个刻度被裁出，必须靠轨内滚动浏览');
    });

    testWidgets('从下沿持续扫掠可连续浏览更靠后的轮次并落点', (tester) async {
      TurnAnchor? selected;
      final anchors = anchors100();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: TurnNavigatorRail(
              anchors: anchors,
              activeTurn: 10,
              busyTurn: null,
              onNavigate: (a) => selected = a,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final bounds = tester.getRect(find.byType(TurnNavigatorRail));
      final gesture = await tester.startGesture(
        Offset(bounds.center.dx, bounds.bottom - 6),
      );
      await gesture.moveBy(const Offset(0, 6)); // 越过拖动 slop，进入扫掠
      await tester.pump();
      await tester.pump(const Duration(seconds: 2)); // 按住不动：边缘自动滚动
      await gesture.up();
      await tester.pumpAndSettle();

      expect(selected, isNotNull);
      expect(selected!.turn, greaterThan(42),
          reason: '贴住下沿应持续推进轨内滚动，扫到第一屏之外的轮次');
    });

    testWidgets('从上沿持续扫掠可连续浏览更靠前的轮次并落点', (tester) async {
      TurnAnchor? selected;
      final anchors = anchors100();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: TurnNavigatorRail(
              anchors: anchors,
              activeTurn: 90,
              busyTurn: null,
              onNavigate: (a) => selected = a,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final bounds = tester.getRect(find.byType(TurnNavigatorRail));
      final gesture = await tester.startGesture(
        Offset(bounds.center.dx, bounds.top + 6),
      );
      await gesture.moveBy(const Offset(0, -6));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(selected, isNotNull);
      expect(selected!.turn, lessThan(58),
          reason: '贴住上沿应反向推进轨内滚动');
    });

    testWidgets('取消扫掠：停止自动滚动且不落点', (tester) async {
      TurnAnchor? selected;
      final anchors = anchors100();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: TurnNavigatorRail(
              anchors: anchors,
              activeTurn: 10,
              busyTurn: null,
              onNavigate: (a) => selected = a,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final bounds = tester.getRect(find.byType(TurnNavigatorRail));
      final gesture = await tester.startGesture(
        Offset(bounds.center.dx, bounds.bottom - 6),
      );
      await gesture.moveBy(const Offset(0, 6));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(selected, isNull, reason: '取消手势不得落点');
    });
  });
}
