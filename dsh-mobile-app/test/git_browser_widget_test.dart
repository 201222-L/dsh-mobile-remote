import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/screens/git_browser_sheet.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _main = GitBranch(
  name: 'refs/heads/main',
  displayName: 'main',
  oid: 'main-oid',
  kind: 'local',
  current: true,
  tracking: 'origin/main',
  ahead: 2,
  behind: 1,
);
const _feature = GitBranch(
  name: 'refs/heads/feature/search',
  displayName: 'feature/search',
  oid: 'feature-oid',
  kind: 'local',
);
const _remote = GitBranch(
  name: 'refs/remotes/origin/main',
  displayName: 'origin/main',
  oid: 'remote-oid',
  kind: 'remote',
);
const _fourth = GitBranch(
  name: 'refs/heads/fourth',
  displayName: 'fourth',
  oid: 'fourth-oid',
  kind: 'local',
);
const _fifth = GitBranch(
  name: 'refs/remotes/origin/fifth',
  displayName: 'origin/fifth',
  oid: 'fifth-oid',
  kind: 'remote',
);
const _sixth = GitBranch(
  name: 'refs/heads/sixth',
  displayName: 'sixth',
  oid: 'sixth-oid',
  kind: 'local',
);

class WidgetGitApi implements GitReadApi {
  WidgetGitApi({this.available = true});

  bool available;
  int graphCalls = 0;
  int commitCalls = 0;
  int worktreeCalls = 0;
  int previewCalls = 0;
  GitWorktreeSnapshot worktreeSnapshot = const GitWorktreeSnapshot(
    repositoryId: 'repo-1',
    snapshotId: 'worktree-1',
    staged: [GitWorktreeFile(path: 'staged.txt', status: 'modified')],
    unstaged: [GitWorktreeFile(path: 'both.txt', status: 'modified')],
    untracked: [GitWorktreeFile(path: 'new.txt', status: 'untracked')],
  );
  final graphRequests = <List<String>>[];
  final graphCursors = <String?>[];
  final filesCursors = <String?>[];
  Completer<GitReadCapabilities>? pendingRefresh;

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async {
    if (pendingRefresh != null) return pendingRefresh!.future;
    return GitReadCapabilities(
      available: available,
      reason: available ? null : 'Git is unavailable here',
    );
  }

  @override
  Future<GitRepository> repository(String sessionId) async =>
      const GitRepository(
        repositoryId: 'repo-1',
        name: 'example',
        headOid: 'main-oid',
        currentBranch: 'refs/heads/main',
      );

  @override
  Future<List<GitBranch>> branches(
    String sessionId,
    String repositoryId,
  ) async => const [_main, _feature, _remote, _fourth, _fifth, _sixth];

  @override
  Future<GitGraphPage> graph(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
  }) async {
    graphCalls++;
    graphRequests.add(tips.map((tip) => tip.name).toList());
    graphCursors.add(cursor);
    if (cursor != null) {
      return GitGraphPage(
        snapshotId: 'snapshot',
        tips: tips,
        commits: const [
          GitCommitSummary(oid: 'page-two', subject: 'Later commit'),
        ],
      );
    }
    return GitGraphPage(
      snapshotId: 'snapshot',
      nextCursor: 'next',
      tips: tips,
      commits: [
        const GitCommitSummary(
          oid: 'main-oid',
          parents: ['parent-oid'],
          author: 'Ada',
          timestamp: 1700000000,
          subject: 'Main subject',
          refs: ['main'],
          tags: ['v1.0'],
        ),
        for (var i = 0; i < 24; i++)
          GitCommitSummary(oid: 'history-$i', subject: 'History $i'),
      ],
    );
  }

  @override
  Future<GitCommitDetails> commitDetails(
    String sessionId,
    String repositoryId,
    String oid, {
    String? filesCursor,
    int filesLimit = 100,
  }) async {
    commitCalls++;
    filesCursors.add(filesCursor);
    if (filesCursor != null) {
      return GitCommitDetails(
        oid: oid,
        files: const [GitCommitFile(path: 'later.dart', additions: 2)],
      );
    }
    return GitCommitDetails(
      oid: oid,
      parents: const ['parent-oid'],
      author: 'Ada',
      timestamp: 1700000000,
      message: 'Main subject\n\nFull message',
      refs: const ['main'],
      tags: const ['v1.0'],
      stats: const GitCommitStats(files: 27, additions: 12, deletions: 3),
      filesTotal: 27,
      filesNextCursor: 'files-next',
      files: [
        const GitCommitFile(path: 'first.dart', additions: 4, deletions: 1),
        for (var i = 0; i < 24; i++) GitCommitFile(path: 'file-$i.dart'),
      ],
    );
  }

  @override
  Future<GitWorktreeSnapshot> worktree(
    String sessionId,
    String repositoryId,
  ) async {
    worktreeCalls++;
    return worktreeSnapshot;
  }

  @override
  Future<GitFilePreview> preview(
    String sessionId,
    String repositoryId, {
    required String kind,
    required String path,
    String? snapshotId,
    String? oid,
  }) async {
    previewCalls++;
    return GitFilePreview(
      repositoryId: repositoryId,
      kind: kind,
      path: path,
      diff: kind == 'untracked'
          ? 'line one\n\nindex literal\ndiff --git literal\nBinary files are source text\n'
          : 'diff --git a/$path b/$path\n@@ -1,10 +1,10 @@\n keep 1\n keep 2\n keep 3\n-old line\n+new line\n--- source -- marker\n+++ source ++ marker\n keep 4\n keep 5\n keep 6\n keep 7\n keep 8\n keep 9\n keep 10\n',
    );
  }
}

AppStore makeStore() {
  final store = AppStore();
  store.sessionId = 'session-1';
  store.sessions = [Session(id: 'session-1', title: 'Test', createdAt: 0)];
  return store;
}

Api makeChatApi() {
  final client = MockClient((request) async {
    final body = switch (request.url.path) {
      '/m/api/history' => {'ok': true, 'events': <Object>[], 'hasMore': false},
      '/m/api/queue' => {'ok': true, 'rows': <Object>[]},
      '/m/api/todos' => {'ok': true, 'todos': <Object>[]},
      '/m/api/session-config' => {'ok': true, 'config': <String, dynamic>{}},
      _ => {'ok': true},
    };
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  return Api(client: client)
    ..baseUrl = 'http://chat.test'
    ..path = '/m'
    ..token = ''
    ..timelineCapabilities = const TimelineCapabilities(
      version: 1,
      live: true,
      history: true,
      detail: true,
      unknownEvents: true,
      callCorrelation: true,
    );
}

Future<GitBrowserController> mountSheet(
  WidgetTester tester,
  WidgetGitApi api, {
  List<String> tabs = const ['branches', 'graph', 'worktree'],
}) async {
  final controller = GitBrowserController(api);
  final graphScrollController = ScrollController();
  addTearDown(graphScrollController.dispose);
  await controller.open('session-1');
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 700,
          child: GitBrowserSheet(
            controller: controller,
            scrollController: graphScrollController,
            tabs: tabs,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  setUp(() => L10n.lang = 'en');
  tearDown(() => L10n.lang = 'zh');

  testWidgets('conversation action rail keeps Git navigation full-screen', (
    tester,
  ) async {
    L10n.lang = 'zh';
    final gitApi = WidgetGitApi(available: false);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          store: makeStore(),
          apiClient: makeChatApi(),
          onTitleChanged: () {},
          gitReadApi: gitApi,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    await tester.tap(find.byTooltip('对话操作'));
    await tester.pumpAndSettle();

    final git = find.byTooltip('Git');
    final tools = find.byTooltip('任务 / 子代理 / 目标');
    expect(git, findsOneWidget);
    expect(tools, findsOneWidget);
    expect(tester.getTopLeft(git).dy, lessThan(tester.getTopLeft(tools).dy));

    await tester.tap(git);
    await tester.pumpAndSettle();
    expect(find.text('Git is unavailable here'), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byTooltip('返回聊天'), findsOneWidget);
    expect(find.byTooltip('对话操作'), findsNothing);
    await tester.tap(find.byTooltip('返回聊天'));
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsNothing);
    expect(find.byTooltip('返回聊天'), findsNothing);
  });

  testWidgets(
    'grouped branches search and display current tracking divergence',
    (tester) async {
      final api = WidgetGitApi();
      final controller = await mountSheet(tester, api);
      addTearDown(controller.dispose);
      expect(find.text('Local branches'), findsOneWidget);
      expect(find.text('Remote branches'), findsOneWidget);
      expect(find.text('origin/main  ↑2  ↓1'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('git-branch-search')),
        'feature',
      );
      await tester.pumpAndSettle();
      expect(find.text('feature/search'), findsOneWidget);
      expect(find.byKey(const Key('git-branch-refs/heads/main')), findsNothing);
      expect(api.graphCalls, 0);
      await tester.tap(find.text('feature/search'));
      await tester.pumpAndSettle();
      expect(controller.state.selectedBranches.map((branch) => branch.name), [
        'refs/heads/feature/search',
      ]);
      expect(api.graphRequests.last, ['refs/heads/feature/search']);
      expect(find.text('Main subject'), findsOneWidget);
    },
  );

  testWidgets('untracked preview preserves blank and diff-like source lines', (
    tester,
  ) async {
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);

    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-untracked-new.txt')));
    await tester.pumpAndSettle();

    expect(find.text('line one'), findsOneWidget);
    expect(find.byKey(const Key('git-diff-line-1')), findsOneWidget);
    expect(find.text('index literal'), findsOneWidget);
    expect(find.text('diff --git literal'), findsOneWidget);
    expect(find.text('Binary files are source text'), findsOneWidget);
  });

  testWidgets(
    'graph-first preference with multiple tabs opens the default branch',
    (tester) async {
      final api = WidgetGitApi();
      final controller = await mountSheet(
        tester,
        api,
        tabs: const ['graph', 'worktree'],
      );
      addTearDown(controller.dispose);

      await tester.pumpAndSettle();
      expect(api.graphRequests.first, ['refs/heads/main']);
      expect(find.text('main'), findsWidgets);
      expect(find.byType(TabBar), findsOneWidget);
      await tester.tap(find.text('Worktree'));
      await tester.pumpAndSettle();
      expect(api.worktreeCalls, 1);
      expect(find.text('Staged (1)'), findsOneWidget);
    },
  );

  testWidgets('hidden graph opens temporarily and returns to the branch tab', (
    tester,
  ) async {
    final api = WidgetGitApi();
    final controller = await mountSheet(
      tester,
      api,
      tabs: const ['branches', 'worktree'],
    );
    addTearDown(controller.dispose);

    await tester.tap(find.text('feature/search'));
    await tester.pumpAndSettle();
    expect(find.text('Main subject'), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Local branches'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
  });

  testWidgets('worktree tab lists changes and opens a foldable line preview', (
    tester,
  ) async {
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);

    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    expect(api.worktreeCalls, 1);
    expect(find.text('Staged (1)'), findsOneWidget);
    expect(find.text('Unstaged (1)'), findsOneWidget);
    expect(find.text('Untracked (1)'), findsOneWidget);
    expect(
      find.byKey(const Key('git-worktree-staged-staged.txt')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('git-worktree-untracked-new.txt')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('git-worktree-staged-staged.txt')));
    await tester.pumpAndSettle();
    expect(api.previewCalls, 1);
    expect(find.byKey(const Key('git-file-preview')), findsOneWidget);
    expect(find.text('new line'), findsOneWidget);
    expect(find.text('-- source -- marker'), findsOneWidget);
    expect(find.text('++ source ++ marker'), findsOneWidget);
    expect(find.text('-'), findsNWidgets(2));
    expect(find.text('+'), findsNWidgets(2));
    expect(find.byKey(const Key('git-context-fold-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-context-fold-0')));
    await tester.pumpAndSettle();
    expect(find.text('keep 7'), findsOneWidget);
  });

  testWidgets('graph branch picker permits five refs and explains the limit', (
    tester,
  ) async {
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-graph-filter')));
    await tester.pumpAndSettle();
    final main = find.byKey(const Key('git-filter-refs/heads/main'));
    await tester.tap(main);
    await tester.pumpAndSettle();
    expect(controller.state.selectedBranches.length, 1);
    await tester.enterText(find.byKey(const Key('git-graph-search')), 'origin');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('git-filter-refs/heads/feature/search')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('git-filter-refs/remotes/origin/main')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('git-graph-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('git-filter-refs/heads/feature/search')),
    );
    await tester.pumpAndSettle();
    expect(controller.state.selectedBranches.length, 3);

    final pickerScroll = find.descendant(
      of: find.byKey(const Key('git-graph-branch-list')),
      matching: find.byType(Scrollable),
    );
    final fourth = find.byKey(const Key('git-filter-refs/heads/fourth'));
    await tester.scrollUntilVisible(fourth, 80, scrollable: pickerScroll);
    await tester.tap(fourth);
    await tester.pumpAndSettle();
    final fifth = find.byKey(const Key('git-filter-refs/remotes/origin/fifth'));
    await tester.scrollUntilVisible(fifth, 80, scrollable: pickerScroll);
    await tester.tap(fifth);
    await tester.pumpAndSettle();
    expect(controller.state.selectedBranches.length, 5);

    final sixth = find.byKey(const Key('git-filter-refs/heads/sixth'));
    await tester.scrollUntilVisible(sixth, 80, scrollable: pickerScroll);
    await tester.tap(sixth);
    await tester.pumpAndSettle();
    expect(controller.state.selectedBranches.length, 5);
    expect(api.graphRequests.last.length, 5);
    expect(find.text('Select up to 5 branches'), findsOneWidget);
  });

  testWidgets(
    'one horizontal graph viewport isolates swipes; vertical scroll paginates',
    (tester) async {
      final api = WidgetGitApi();
      final controller = await mountSheet(tester, api);
      addTearDown(controller.dispose);
      await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('git-graph-horizontal')), findsOneWidget);
      expect(
        find
            .byType(Scrollable)
            .evaluate()
            .where(
              (element) =>
                  (element.widget as Scrollable).axisDirection ==
                  AxisDirection.right,
            )
            .length,
        1,
      );
      expect(api.graphCalls, 1);
      expect(find.text('main'), findsWidgets); // graph ref badge
      expect(find.text('v1.0'), findsOneWidget); // graph tag badge
      final graphRow = find.descendant(
        of: find.byKey(const Key('git-commit-main-oid')),
        matching: find.byType(CustomPaint),
      );
      final firstRow =
          (tester.widget<CustomPaint>(graphRow.first).painter as dynamic).row;
      expect(firstRow.hasIncomingEdge, isFalse);
      await tester.drag(
        find.byKey(const Key('git-graph-horizontal')),
        const Offset(-250, 0),
      );
      await tester.pumpAndSettle();
      expect(api.graphCalls, 1);
      await tester.drag(
        find.byKey(const Key('git-graph-vertical')),
        const Offset(0, -2200),
      );
      await tester.pumpAndSettle();
      expect(api.graphCursors, [null, 'next']);
      expect(controller.state.commits.last.oid, 'page-two');
      final vertical = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('git-graph-vertical')),
          matching: find.byType(Scrollable),
        ),
      );
      vertical.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        (tester.widget<CustomPaint>(graphRow.first).painter as dynamic).row,
        same(firstRow),
      );
    },
  );

  testWidgets('stale banner preserves graph until explicit refresh', (
    tester,
  ) async {
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    final calls = api.graphCalls;
    controller.markStale();
    await tester.pump();
    expect(find.text('Graph is stale. Refresh to update.'), findsOneWidget);
    expect(find.text('Main subject'), findsOneWidget);
    expect(api.graphCalls, calls);
    api.pendingRefresh = Completer<GitReadCapabilities>();
    await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
    await tester.pump();
    expect(find.text('Main subject'), findsOneWidget);
    api.pendingRefresh!.complete(const GitReadCapabilities(available: true));
    await tester.pumpAndSettle();
    expect(controller.state.stale, isFalse);
    expect(api.graphCalls, calls + 1);
    expect(find.text('Main subject'), findsOneWidget);
  });

  testWidgets('commit detail renders metadata and paginates read-only files', (
    tester,
  ) async {
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-commit-main-oid')));
    await tester.pumpAndSettle();
    expect(find.text('Main subject\n\nFull message'), findsOneWidget);
    expect(find.text('Author: Ada'), findsOneWidget);
    expect(find.text('OID: main-oid'), findsOneWidget);
    expect(find.text('Parents: parent-oid'), findsOneWidget);
    expect(find.text('Refs: main'), findsOneWidget);
    expect(find.text('Tags: v1.0'), findsOneWidget);
    expect(find.text('Stats: 27 files · +12 −3'), findsOneWidget);
    expect(find.text('first.dart'), findsOneWidget);
    expect(find.textContaining('Ada@'), findsNothing);
    expect(find.textContaining('diff --git'), findsNothing);
    await tester.drag(
      find.byKey(const Key('git-detail-list')),
      const Offset(0, -2200),
    );
    await tester.pumpAndSettle();
    expect(api.filesCursors, [null, 'files-next']);
    expect(controller.state.commit!.files.last.path, 'later.dart');
  });
}
