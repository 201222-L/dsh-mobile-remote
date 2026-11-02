// 文件历史 body 的“浏览器选择 vs 内联搜索”入口测试（issue #42 UX 变更）。
import 'package:dsh_mobile_app/git_file_history_controller.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/widgets/git_file_history_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'git_history_fake.dart';

Future<GitFileHistoryController> mountBody(
  WidgetTester tester, {
  HistoryGitApi? api,
  Future<void> Function()? onBrowseFiles,
  bool autoOpenPicker = false,
}) async {
  final controller = GitFileHistoryController(
    api: api ?? HistoryGitApi(),
    sessionId: 'session-1',
    repositoryId: 'repo-1',
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          width: 520,
          child: GitFileHistoryBody(
            controller: controller,
            onBrowseFiles: onBrowseFiles,
            autoOpenPickerWhenEmpty: autoOpenPicker,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  setUp(() {
    L10n.lang = 'en';
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => L10n.lang = 'zh');

  testWidgets('primary choose opens file browser, secondary search opens inline picker', (
    tester,
  ) async {
    var browseCalls = 0;
    await mountBody(
      tester,
      onBrowseFiles: () async => browseCalls++,
    );

    // 主入口：会话文件浏览器；内联选择器不自动/直接打开。
    await tester.tap(find.byKey(const Key('git-history-change')));
    await tester.pumpAndSettle();
    expect(browseCalls, 1);
    expect(find.byKey(const Key('git-history-picker')), findsNothing);

    // 次要入口：搜索文件 → 仍可打开内联选择器。
    expect(find.byKey(const Key('git-history-search-files')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-history-search-files')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-history-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsNothing);
  });

  testWidgets('guided empty state offers browser primary and search secondary', (
    tester,
  ) async {
    var browseCalls = 0;
    await mountBody(tester, onBrowseFiles: () async => browseCalls++);

    expect(find.byKey(const Key('git-history-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-history-choose')));
    await tester.pumpAndSettle();
    expect(browseCalls, 1);
    expect(find.byKey(const Key('git-history-picker')), findsNothing);

    await tester.tap(find.byKey(const Key('git-history-search-empty')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
  });

  testWidgets('browser null/cancel leaves the current selection unchanged', (
    tester,
  ) async {
    final controller = await mountBody(
      tester,
      onBrowseFiles: () async {
        // 模拟浏览器返回 null：宿主不做 selectFile。
      },
    );
    await controller.selectFile('lib/a.dart');
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);

    await tester.tap(find.byKey(const Key('git-history-change')));
    await tester.pumpAndSettle();
    expect(controller.selectedPath, 'lib/a.dart');
    expect(find.text('Update a.dart'), findsOneWidget);
  });

  testWidgets('without onBrowseFiles the inline picker stays primary (legacy)', (
    tester,
  ) async {
    await mountBody(tester);
    expect(find.byKey(const Key('git-history-search-files')), findsNothing);

    await tester.tap(find.byKey(const Key('git-history-change')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
  });

  testWidgets('auto-open-once still opens inline picker, never the browser', (
    tester,
  ) async {
    var browseCalls = 0;
    await mountBody(
      tester,
      onBrowseFiles: () async => browseCalls++,
      autoOpenPicker: true,
    );
    // 无文件时自动打开的是内联选择器（continue existing behavior）。
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
    expect(browseCalls, 0);
    await tester.tap(find.byKey(const Key('git-history-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-empty')), findsOneWidget);
  });
}
