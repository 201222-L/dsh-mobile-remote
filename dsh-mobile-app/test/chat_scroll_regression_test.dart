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

    testWidgets('顶部负向 overscroll 允许重试分页', (tester) async {
      final context = await testContext(tester);
      final notification = OverscrollNotification(
        metrics: metrics(pixels: 0),
        context: context,
        overscroll: -12,
      );
      expect(shouldLoadOlderFromScroll(notification, infiniteMode: true), isTrue);
    });

    testWidgets('顶部正向 overscroll 不触发分页', (tester) async {
      final context = await testContext(tester);
      final notification = OverscrollNotification(
        metrics: metrics(pixels: 0),
        context: context,
        overscroll: 12,
      );
      expect(shouldLoadOlderFromScroll(notification, infiniteMode: true), isFalse);
    });
  });

  testWidgets('centered live slivers preserve offset when older rows are prepended', (tester) async {
    final controller = ScrollController();
    final centerKey = const ValueKey<String>('center');
    var older = <int>[];
    final current = List<int>.generate(20, (i) => i);
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return CustomScrollView(
            controller: controller,
            center: centerKey,
            slivers: [
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, index) => SizedBox(height: 100, child: Text('old ${older[index]}')),
                  childCount: older.length,
                ),
              ),
              SliverToBoxAdapter(key: centerKey, child: const SizedBox.shrink()),
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, index) => SizedBox(height: 100, child: Text('current ${current[current.length - 1 - index]}')),
                  childCount: current.length,
                ),
              ),
            ],
          );
        },
      ),
    ));
    await tester.pump();
    controller.jumpTo(controller.position.maxScrollExtent - 150);
    await tester.pump();
    final before = controller.offset;
    update(() => older = List<int>.generate(10, (i) => i + 20));
    await tester.pumpAndSettle();
    expect(controller.offset, before);
  });
}
