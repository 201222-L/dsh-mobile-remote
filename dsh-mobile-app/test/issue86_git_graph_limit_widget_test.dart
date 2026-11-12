// issue #86：Git 分支图上限三档的 widget 回归。
//
// 覆盖：设置页三档与持久化；筛选面板「已选 N / 上限 …」；5/10 触顶快捷 sheet
// （改档保留选择、降档裁剪+toast）；unlimited 全选仅当前搜索结果/清空；
// 仅 unlimited 的 30s 超时面板（取消迟到响应、三动作、不自动降档）；
// 320/深色无 overflow；5/10 不触发超时。

import 'dart:async';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/screens/git_browser_sheet.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _branchCount = 12;

GitBranch _branch(int i) => GitBranch(
  name: 'refs/heads/b$i',
  displayName: 'b$i',
  oid: 'oid-$i',
  kind: 'local',
  current: i == 0,
);

class _FakeGitApi implements GitReadApi {
  _FakeGitApi({this.capsOverride});
  final GitReadCapabilities? capsOverride;
  final List<List<String>> graphTips = [];
  Completer<GitGraphPage>? graphGate;
  Completer<GitGraphPage>? pageGate;
  bool hasSecondPage = false;
  int graphCalls = 0;

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async =>
      capsOverride ??
      const GitReadCapabilities(
        available: true,
        graphTipsMax: 128,
        graphTipsGetMax: 32,
      );

  @override
  Future<GitRepository> repository(String sessionId) async =>
      const GitRepository(
        repositoryId: 'repo',
        name: 'repo',
        headOid: 'oid-0',
        currentBranch: 'refs/heads/b0',
      );

  @override
  Future<List<GitBranch>> branches(String sessionId, String repositoryId) async =>
      [for (var i = 0; i < _branchCount; i++) _branch(i)];

  @override
  Future<GitGraphPage> graph(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
    Duration timeout = const Duration(seconds: 15),
  }) {
    graphCalls++;
    graphTips.add(tips.map((tip) => tip.name).toList());
    if (cursor != null && pageGate != null) return pageGate!.future;
    if (graphGate != null) return graphGate!.future;
    return Future.value(
      GitGraphPage(
        snapshotId: 'snapshot',
        nextCursor: hasSecondPage && cursor == null ? 'cursor-1' : null,
        tips: tips,
      ),
    );
  }

  @override
  Future<GitCommitDetails> commitDetails(
    String sessionId,
    String repositoryId,
    String oid, {
    String? filesCursor,
    int filesLimit = 100,
  }) async => GitCommitDetails(oid: oid);

  @override
  Future<GitWorktreeSnapshot> worktree(String sessionId, String repositoryId) async =>
      const GitWorktreeSnapshot(repositoryId: 'repo', snapshotId: 'wt');

  @override
  Future<GitFilePreview> preview(
    String sessionId,
    String repositoryId, {
    required String kind,
    required String path,
    String? snapshotId,
    String? oid,
  }) async => GitFilePreview(repositoryId: repositoryId, kind: kind, path: path);

  @override
  Future<GitFileList> files(
    String sessionId,
    String repositoryId, {
    String? q,
    int limit = 200,
  }) async => const GitFileList();

  @override
  Future<GitFileHistoryPage> fileHistory(
    String sessionId,
    String repositoryId, {
    required String path,
    String? cursor,
    int limit = 20,
  }) async => const GitFileHistoryPage();
}

Future<({GitBrowserController controller, AppStore store})> _mountSheet(
  WidgetTester tester, {
  GitGraphBranchLimit limit = GitGraphBranchLimit.five,
  _FakeGitApi? api,
  Size? size,
  bool dark = false,
}) async {
  final controller = GitBrowserController(api ?? _FakeGitApi(), branchLimit: limit);
  final store = AppStore()..gitGraphBranchLimit = limit;
  final scroll = ScrollController();
  // 真实视口：否则 tester 默认 800×600，底部 sheet 的选项会落在不可点区域。
  tester.view.physicalSize = size ?? const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: dark ? ThemeData.dark() : ThemeData.light(),
    home: Scaffold(
      body: GitBrowserSheet(
        controller: controller,
        scrollController: scroll,
        tabs: const ['graph'],
        store: store,
      ),
    ),
  ));
  await controller.open('session-a');
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 200));
  return (controller: controller, store: store);
}

Future<void> _openFilter(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('git-graph-filter')));
  await tester.pump(const Duration(milliseconds: 200));
}

/// 分支筛选列表是懒构建的：目标不在视口内时先滚动到可见再点。
Future<void> _tapBranchFilter(WidgetTester tester, int index) async {
  final target = find.byKey(Key('git-filter-refs/heads/b$index'));
  if (target.evaluate().isEmpty) {
    final scrollable = find.descendant(
      of: find.byKey(const Key('git-graph-branch-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(target, 80, scrollable: scrollable);
  }
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    L10n.lang = 'en';
  });

  testWidgets('筛选面板显示「已选 N / 上限 …」，5/10 不显示全选/清空', (tester) async {
    final mounted = await _mountSheet(tester);
    addTearDown(mounted.controller.dispose);
    await _openFilter(tester);
    expect(find.byKey(const Key('git-graph-limit-status')), findsOneWidget);
    expect(find.text('Selected 1 / limit 5'), findsOneWidget);
    expect(find.byKey(const Key('git-graph-select-all')), findsNothing);
    expect(find.byKey(const Key('git-graph-clear')), findsNothing);
  });

  testWidgets('5 档触顶弹出快捷 sheet；升到 10 保留选择后可继续勾选', (tester) async {
    final mounted = await _mountSheet(tester);
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    for (var i = 1; i < 5; i++) {
      await controller.toggleGraphBranch(_branch(i));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await _openFilter(tester);
    expect(find.text('Selected 5 / limit 5'), findsOneWidget);
    // 达上限 chip：状态旁可点入口。
    expect(find.byKey(const Key('git-graph-limit-reached')), findsOneWidget);

    await _tapBranchFilter(tester, 5);
    expect(find.byKey(const Key('git-graph-limit-10')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-limit-cancel')), findsOneWidget);
    expect(controller.state.selectedBranches, hasLength(5));

    await tester.tap(find.byKey(const Key('git-graph-limit-10')));
    await tester.pumpAndSettle();
    expect(controller.branchLimit, GitGraphBranchLimit.ten);
    expect(mounted.store.gitGraphBranchLimit, GitGraphBranchLimit.ten);
    // 升档后自动补选触发项（仍在当前搜索结果内）。
    expect(controller.state.selectedBranches, hasLength(6));
    expect(find.text('Selected 6 / limit 10'), findsOneWidget);
  });

  testWidgets('降档裁剪前 N 并 toast；改档写全局偏好', (tester) async {
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.ten,
    );
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    for (var i = 1; i < 10; i++) {
      await controller.toggleGraphBranch(_branch(i));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await _openFilter(tester);
    expect(find.text('Selected 10 / limit 10'), findsOneWidget);

    // 直接调用快捷 sheet 的降档路径（避免再勾第 9 个的多余步骤）：通过 controller 改档
    // 是 UI 快捷 sheet 的同一入口；这里再断言 toast 需要走 UI——点第 9 个触发 sheet 更真实。
    // 触顶后（选第 11 个）弹快捷 sheet，再降到 5 档 → 裁剪前 5 + toast。
    await _tapBranchFilter(tester, 10);
    await tester.tap(find.byKey(const Key('git-graph-limit-5')));
    await tester.pumpAndSettle();
    expect(controller.branchLimit, GitGraphBranchLimit.five);
    expect(controller.state.selectedBranches, hasLength(5));
    expect(
      find.textContaining('Kept the first 5'),
      findsOneWidget,
      reason: '降档裁剪后 toast 提示保留数量',
    );
    expect(mounted.store.gitGraphBranchLimit, GitGraphBranchLimit.five);
  });

  testWidgets('unlimited：全选只作用于当前搜索结果；清空后显示未选择占位', (tester) async {
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.unlimited,
    );
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    expect(controller.state.selectedBranches, hasLength(1), reason: '不自动全选');
    await _openFilter(tester);
    expect(find.text('Selected 1 / limit Unlimited'), findsOneWidget);
    expect(find.byKey(const Key('git-graph-select-all')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-clear')), findsOneWidget);

    // 搜索过滤到 b1*（b1、b10、b11 三个）。
    await tester.enterText(find.byKey(const Key('git-graph-search')), 'b1');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('git-graph-select-all')));
    await tester.pump(const Duration(milliseconds: 400));
    // union：搜索外已选 b0 保留，搜索结果 b1/b10/b11 加入 → 4。
    expect(controller.state.selectedBranches, hasLength(4));
    expect(
      controller.state.selectedBranches.map((b) => b.displayName),
      containsAll(['b0', 'b1', 'b10', 'b11']),
    );
    expect(find.text('Selected 4 / limit Unlimited'), findsOneWidget);

    await tester.tap(find.byKey(const Key('git-graph-clear')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.state.selectedBranches, isEmpty);
    expect(find.byKey(const Key('git-graph-empty-selection')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-empty-pick')), findsOneWidget);
  });

  testWidgets('仅 unlimited 启用 30s 超时：迟到响应丢弃、三动作可用、不自动降档', (tester) async {
    final api = _FakeGitApi()..graphGate = Completer<GitGraphPage>();
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.unlimited,
      api: api,
    );
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    // 触发一次 graph 加载（默认分支）。
    unawaited(controller.openBranch(_branch(0)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.state.loadingGraph, isTrue);

    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(controller.branchLimit, GitGraphBranchLimit.unlimited, reason: '不自动降档');
    expect(controller.state.graphTimedOut, isTrue);
    expect(find.text('Load timed out'), findsOneWidget);
    expect(
      find.text(
        'Too many branches or a slow network. Switch back to a 10-branch limit, or try again later.',
      ),
      findsOneWidget,
      reason: 'issue #86 产品定稿：超时正文文案',
    );
    expect(find.byKey(const Key('git-graph-timeout-ten')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-timeout-settings')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-timeout-retry')), findsOneWidget);
    // 「打开设置」不 push 设置页：在当前 Git sheet 内打开同一三档弹层。
    await tester.tap(find.byKey(const Key('git-graph-timeout-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-graph-limit-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-graph-limit-cancel')));
    await tester.pumpAndSettle();

    // 迟到响应不得覆盖超时态（generation 已作废）。
    api.graphGate!.complete(
      const GitGraphPage(snapshotId: 'late', nextCursor: null),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.state.graphTimedOut, isTrue);
    expect(controller.state.commits, isEmpty);

    // 「改回 10 档」：写偏好 + 立即以 10 档重载。
    await tester.tap(find.byKey(const Key('git-graph-timeout-ten')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.branchLimit, GitGraphBranchLimit.ten);
    expect(mounted.store.gitGraphBranchLimit, GitGraphBranchLimit.ten);
  });

  testWidgets('5 档不启用 30s 超时（挂起时仍按普通加载态）', (tester) async {
    final api = _FakeGitApi()..graphGate = Completer<GitGraphPage>();
    final mounted = await _mountSheet(tester, api: api);
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    unawaited(controller.openBranch(_branch(0)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(controller.state.graphTimedOut, isFalse);
    expect(find.byKey(const Key('git-graph-timeout-message')), findsNothing);
  });

  testWidgets('320/深色：筛选面板与 unlimited 操作无 overflow', (tester) async {
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.unlimited,
      size: const Size(320, 700),
      dark: true,
    );
    addTearDown(mounted.controller.dispose);
    await _openFilter(tester);
    expect(find.byKey(const Key('git-graph-select-all')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-clear')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置页三档：默认 5、切 10 后持久化，副标题显示当前值', (tester) async {
    SharedPreferences.setMockInitialValues({'dsh_mr_language': 'en'});
    final store = AppStore();
    await store.loadPrefs();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsScreen(store: store, onReconfigure: () async {}),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final row = find.byKey(const Key('settings-git-graph-limit'));
    await tester.scrollUntilVisible(
      row,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    // 设置行 trailing 显示当前值（不是只在 sub 里）。
    expect(find.descendant(of: row, matching: find.text('5')), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-graph-limit-5')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-limit-10')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-limit-unlimited')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-limit-cancel')), findsOneWidget);
    expect(find.textContaining('Applies to all repositories'), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-graph-limit-10')));
    await tester.pumpAndSettle();
    expect(store.gitGraphBranchLimit, GitGraphBranchLimit.ten);
    expect(find.descendant(of: row, matching: find.text('10')), findsOneWidget);

    final restored = AppStore();
    await restored.loadPrefs();
    expect(restored.gitGraphBranchLimit, GitGraphBranchLimit.ten);
  });
  testWidgets('不限档分页加载不启用 30s 超时（沿用分页路径）', (tester) async {
    final api = _FakeGitApi()
      ..hasSecondPage = true
      ..pageGate = Completer<GitGraphPage>();
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.unlimited,
      api: api,
    );
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    await controller.openBranch(_branch(0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.state.graphNextCursor, 'cursor-1');

    unawaited(controller.loadNextGraphPage());
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.state.loadingGraphPage, isTrue);
    await tester.pump(const Duration(seconds: 31));
    expect(controller.state.graphTimedOut, isFalse,
        reason: '分页加载不启动 30s 计时');
    expect(find.byKey(const Key('git-graph-timeout-message')), findsNothing);
  });

  testWidgets('320 深色：超时卡三动作堆叠、无 overflow；取消不改变档位', (tester) async {
    final api = _FakeGitApi()..graphGate = Completer<GitGraphPage>();
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.unlimited,
      api: api,
      size: const Size(320, 700),
      dark: true,
    );
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    unawaited(controller.openBranch(_branch(0)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(find.byKey(const Key('git-graph-timeout-ten')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-timeout-settings')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-timeout-retry')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '320/深色超时卡无 overflow');

    // 打开设置弹层 → 取消：档位不变、仍是超时态。
    await tester.tap(find.byKey(const Key('git-graph-timeout-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-graph-limit-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-graph-limit-cancel')));
    await tester.pumpAndSettle();
    expect(controller.branchLimit, GitGraphBranchLimit.unlimited);
    expect(controller.state.graphTimedOut, isTrue);
  });
  testWidgets('不限档取消最后一项：允许 0 选择、显示空态、不发起新 graph 请求', (tester) async {
    final api = _FakeGitApi();
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.unlimited,
      api: api,
    );
    addTearDown(mounted.controller.dispose);
    final controller = mounted.controller;
    unawaited(controller.openBranch(_branch(0)));
    await tester.pump(const Duration(milliseconds: 300));
    final callsBefore = api.graphCalls;
    expect(controller.state.selectedBranches, hasLength(1));

    await _openFilter(tester);
    await tester.tap(find.byKey(const Key('git-filter-refs/heads/b0')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.state.selectedBranches, isEmpty);
    expect(find.byKey(const Key('git-graph-empty-selection')), findsOneWidget);
    expect(find.text('Selected 0 / limit Unlimited'), findsOneWidget);
    expect(api.graphCalls, callsBefore, reason: '0 选择不应发起 graph 请求');
  });
  testWidgets('旧宿主：已持久化 10 档打开即 clamp 回 5 并说明；快捷 sheet 禁用 10/不限', (tester) async {
    final api = _FakeGitApi(
      capsOverride: const GitReadCapabilities(available: true),
    );
    final mounted = await _mountSheet(
      tester,
      limit: GitGraphBranchLimit.ten,
      api: api,
    );
    addTearDown(mounted.controller.dispose);
    expect(mounted.controller.branchLimit, GitGraphBranchLimit.five);
    expect(mounted.store.gitGraphBranchLimit, GitGraphBranchLimit.five);
    expect(
      find.textContaining('Desktop version too old'),
      findsOneWidget,
      reason: '一次性说明电脑端版本过低',
    );

    // 5 档触顶 → 快捷 sheet；旧宿主 10/不限不可点。
    for (var i = 1; i < 5; i++) {
      await mounted.controller.toggleGraphBranch(_branch(i));
    }
    await tester.pump(const Duration(milliseconds: 100));
    await _openFilter(tester);
    await _tapBranchFilter(tester, 5);
    expect(find.byKey(const Key('git-graph-limit-10')), findsOneWidget);
    final ten = tester.widget<InkWell>(
      find.byKey(const Key('git-graph-limit-10')),
    );
    expect(ten.onTap, isNull, reason: '旧宿主不得升到 10 档');
    final unlimited = tester.widget<InkWell>(
      find.byKey(const Key('git-graph-limit-unlimited')),
    );
    expect(unlimited.onTap, isNull);
    expect(find.textContaining('Unsupported by this desktop version'), findsWidgets);
    await tester.tap(find.byKey(const Key('git-graph-limit-cancel')));
    await tester.pumpAndSettle();
  });
}
