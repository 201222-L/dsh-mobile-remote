import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FixedScrollMetrics metrics({
  AxisDirection direction = AxisDirection.down,
  double pixels = 0,
  double max = 1000,
}) =>
    FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: max,
      pixels: pixels,
      viewportDimension: 600,
      axisDirection: direction,
      devicePixelRatio: 1,
    );

Future<BuildContext> testContext(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SizedBox(key: Key('context'))));
  return tester.element(find.byKey(const Key('context')));
}

void main() {
  group('shouldLoadOlderFromScroll', () {
    testWidgets('顶部的 ScrollStart/ScrollEnd 不触发分页（横滑手势竞争回归）', (tester) async {
      final context = await testContext(tester);
      final m = metrics(pixels: 0);
      expect(
        shouldLoadOlderFromScroll(ScrollStartNotification(metrics: m, context: context), infiniteMode: true),
        isFalse,
      );
      expect(
        shouldLoadOlderFromScroll(ScrollEndNotification(metrics: m, context: context), infiniteMode: true),
        isFalse,
      );
    });

    testWidgets('实际向顶部滚动的纵向 update 才触发分页', (tester) async {
      final context = await testContext(tester);
      final notification = ScrollUpdateNotification(
        metrics: metrics(pixels: 40),
        context: context,
        scrollDelta: -20,
        dragDetails: DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: const Offset(0, 20),
        ),
      );
      expect(shouldLoadOlderFromScroll(notification, infiniteMode: true), isTrue);
    });

    testWidgets('横向 update 不触发分页', (tester) async {
      final context = await testContext(tester);
      final notification = ScrollUpdateNotification(
        metrics: metrics(direction: AxisDirection.right, pixels: 0),
        context: context,
        scrollDelta: 20,
      );
      expect(shouldLoadOlderFromScroll(notification, infiniteMode: true), isFalse);
    });

    testWidgets('向最新方向的纵向 update 不触发分页', (tester) async {
      final context = await testContext(tester);
      final notification = ScrollUpdateNotification(
        metrics: metrics(pixels: 40),
        context: context,
        scrollDelta: 20,
      );
      expect(shouldLoadOlderFromScroll(notification, infiniteMode: true), isFalse);
    });
  });

  group('offsetAfterHistoryPrepend', () {
    test('按新增内容高度补偿 offset，原可见消息不移动', () {
      expect(
        offsetAfterHistoryPrepend(
          oldPixels: 0,
          oldMaxScrollExtent: 2200,
          newMaxScrollExtent: 3450,
        ),
        1250,
      );
    });

    test('没有新增 extent 时保持原 offset，并限制在新范围内', () {
      expect(
        offsetAfterHistoryPrepend(
          oldPixels: 40,
          oldMaxScrollExtent: 2200,
          newMaxScrollExtent: 2200,
        ),
        40,
      );
      expect(
        offsetAfterHistoryPrepend(
          oldPixels: 2300,
          oldMaxScrollExtent: 2400,
          newMaxScrollExtent: 2200,
        ),
        2200,
      );
    });
  });
}
