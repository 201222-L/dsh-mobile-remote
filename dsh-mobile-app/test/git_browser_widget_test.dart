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
  final historyPaths = <String>[];
  Completer<GitReadCapabilities>? pendingRefresh;
  bool structuredDetails = false;
  bool emptyDetails = false;

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async {
    if (pendingRefresh != null) return pendingRefresh!.future;
    return GitReadCapabilities(
      available: available,
      reason: available ? null : 'Git is unavailable here',
      // task-28：此 fake 模拟新宿主（10/不限可用；GET≤32/POST≤128）。
      graphTipsMax: 128,
      graphTipsGetMax: 32,
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
    Duration timeout = const Duration(seconds: 15),
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
          i == 0
              ? const GitCommitSummary(
                  oid: 'history-0',
                  subject: 'History 0',
                  decoration: GitDecoration(
                    refs: [
                      GitRefDetail(
                        kind: 'localBranch',
                        name:
                            'refs/heads/feature/very-long-branch-name-that-would-have-been-ellipsized',
                        shortName:
                            'feature/very-long-branch-name-that-would-have-been-ellipsized',
                        oid: 'history-0',
                      ),
                      GitRefDetail(
                        kind: 'localBranch',
                        name: 'refs/heads/feature',
                        shortName: 'feature',
                        oid: 'history-0',
                      ),
                      GitRefDetail(
                        kind: 'localBranch',
                        name: 'refs/heads/feature',
                        shortName: 'feature',
                        oid: 'history-0',
                      ),
                      GitRefDetail(
                        kind: 'remoteBranch',
                        name: 'refs/remotes/origin/main',
                        shortName: 'origin/main',
                        oid: 'history-0',
                      ),
                      GitRefDetail(
                        kind: 'other',
                        name: 'refs/stash',
                        shortName: 'stash',
                        oid: 'history-0',
                      ),
                    ],
                    tags: [
                      GitTagDetail(
                        name: 'refs/tags/v2.0.0-rc.1',
                        shortName: 'v2.0.0-rc.1',
                        oid: 'history-0',
                        annotated: true,
                      ),
                      GitTagDetail(
                        name: 'refs/tags/release-2026',
                        shortName: 'release-2026',
                        oid: 'history-0',
                      ),
                    ],
                  ),
                )
              : GitCommitSummary(oid: 'history-$i', subject: 'History $i'),
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
    if (structuredDetails) {
      return GitCommitDetails(
        oid: oid,
        message: 'Main subject\n\nFull message',
        decoration: const GitDecoration(
          refs: [
            GitRefDetail(
              kind: 'head',
              name: 'refs/heads/main',
              shortName: 'main',
              oid: 'main-oid',
              current: true,
            ),
            GitRefDetail(
              kind: 'localBranch',
              name: 'refs/heads/feature',
              shortName: 'feature',
              oid: 'main-oid',
            ),
            GitRefDetail(
              kind: 'remoteBranch',
              name: 'refs/remotes/origin/main',
              shortName: 'origin/main',
              oid: 'main-oid',
            ),
          ],
          tags: [
            GitTagDetail(
              name: 'refs/tags/v2.0',
              shortName: 'v2.0',
              oid: 'main-oid',
              annotated: true,
              tagger: 'Release Bot',
              timestamp: 1700000100,
              subject: 'Release 2.0',
            ),
            GitTagDetail(
              name: 'refs/tags/old',
              shortName: 'old',
              oid: 'main-oid',
              hint: 'non-commit-target',
            ),
          ],
        ),
      );
    }
    if (emptyDetails) {
      return GitCommitDetails(
        oid: oid,
        message: 'Main subject\n\nFull message',
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

  @override
  Future<GitFileList> files(
    String sessionId,
    String repositoryId, {
    String? q,
    int limit = 200,
  }) async => const GitFileList(
    files: ['docs/readme.md', 'lib/main.dart', 'src/a.dart'],
  );

  @override
  Future<GitFileHistoryPage> fileHistory(
    String sessionId,
    String repositoryId, {
    required String path,
    String? cursor,
    int limit = 20,
  }) async {
    historyPaths.add(path);
    return const GitFileHistoryPage();
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

class DynamicMarginGitApi extends WidgetGitApi {
  DynamicMarginGitApi(this.commits);

  final List<GitCommitSummary> commits;

  @override
  Future<GitGraphPage> graph(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    graphCalls++;
    graphRequests.add(tips.map((tip) => tip.name).toList());
    graphCursors.add(cursor);
    if (cursor != null) {
      return GitGraphPage(snapshotId: 'snapshot', tips: tips, commits: const []);
    }
    return GitGraphPage(snapshotId: 'snapshot', tips: tips, commits: commits);
  }
}

class SnapshotMarginGitApi extends DynamicMarginGitApi {
  SnapshotMarginGitApi(super.commits);

  @override
  Future<GitGraphPage> graph(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final page = await super.graph(
      sessionId,
      repositoryId,
      tips,
      snapshotId: snapshotId,
      cursor: cursor,
      limit: limit,
      timeout: timeout,
    );
    final wide = graphCalls.isEven;
    return GitGraphPage(
      snapshotId: 'snapshot-${graphCalls}',
      tips: page.tips,
      commits: wide ? _mergeFirst : _plain,
    );
  }

  static const _plain = <GitCommitSummary>[
    GitCommitSummary(oid: 'main-oid', parents: ['c1'], author: 'A', timestamp: 1, subject: 'c0'),
    GitCommitSummary(oid: 'c1', parents: ['c2'], author: 'A', timestamp: 1, subject: 'c1'),
    GitCommitSummary(oid: 'c2', parents: ['c3'], author: 'A', timestamp: 1, subject: 'c2'),
    GitCommitSummary(oid: 'c3', parents: ['c4'], author: 'A', timestamp: 1, subject: 'c3'),
    GitCommitSummary(oid: 'c4', parents: ['c5'], author: 'A', timestamp: 1, subject: 'c4'),
    GitCommitSummary(oid: 'c5', parents: ['c6'], author: 'A', timestamp: 1, subject: 'c5'),
    GitCommitSummary(oid: 'c6', parents: ['c7'], author: 'A', timestamp: 1, subject: 'c6'),
    GitCommitSummary(oid: 'c7', parents: ['c8'], author: 'A', timestamp: 1, subject: 'c7'),
    GitCommitSummary(oid: 'c8', author: 'A', timestamp: 1, subject: 'c8'),
  ];

  static const _mergeFirst = <GitCommitSummary>[
    GitCommitSummary(oid: 'main-oid', parents: ['side-a', 'c1'], author: 'A', timestamp: 1, subject: 'merge'),
    GitCommitSummary(oid: 'c1', parents: ['c2'], author: 'A', timestamp: 1, subject: 'c1'),
    GitCommitSummary(oid: 'c2', parents: ['c3'], author: 'A', timestamp: 1, subject: 'c2'),
    GitCommitSummary(oid: 'c3', parents: ['c4'], author: 'A', timestamp: 1, subject: 'c3'),
    GitCommitSummary(oid: 'c4', parents: ['c5'], author: 'A', timestamp: 1, subject: 'c4'),
    GitCommitSummary(oid: 'c5', parents: ['c6'], author: 'A', timestamp: 1, subject: 'c5'),
    GitCommitSummary(oid: 'c6', parents: ['c7'], author: 'A', timestamp: 1, subject: 'c6'),
    GitCommitSummary(oid: 'c7', parents: ['c8'], author: 'A', timestamp: 1, subject: 'c7'),
    GitCommitSummary(oid: 'c8', author: 'A', timestamp: 1, subject: 'c8'),
  ];
}

Future<GitBrowserController> mountSheet(
  WidgetTester tester,
  WidgetGitApi api, {
  List<String> tabs = const ['branches', 'graph', 'worktree'],
  Size size = const Size(800, 600),
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = GitBrowserController(api);
  final graphScrollController = ScrollController();
  addTearDown(graphScrollController.dispose);
  await controller.open('session-1');
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
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

  testWidgets('issue #102 P2：首屏 merge 行 2 lane 第一帧即 92', (tester) async {
    final commits = <GitCommitSummary>[
      const GitCommitSummary(oid: 'main-oid', parents: ['side-a', 'c1'], author: 'A', timestamp: 1, subject: 'merge'),
      for (var i = 1; i < 16; i++)
        GitCommitSummary(oid: 'c$i', parents: i < 15 ? ['c${i + 1}'] : const [], author: 'A', timestamp: 1, subject: 'c$i'),
    ];
    final controller = await mountSheet(tester, DynamicMarginGitApi(commits));
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('git-graph-painter-main-oid'))).width, closeTo(92, 1));
  });

  testWidgets('issue #102 P2：snapshot 切换宽/窄各一次', (tester) async {
    final api = SnapshotMarginGitApi(const []);
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('git-graph-painter-main-oid'))).width, 80);
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('git-graph-painter-main-oid'))).width, closeTo(92, 1));
    await controller.refresh();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('git-graph-painter-main-oid'))).width, 80);
  });

  testWidgets('issue #102：可见行最大 lane 动态决定图宽（初始/下滚/回滚 + 150ms）', (tester) async {
    final commits = <GitCommitSummary>[
      for (var i = 0; i < 24; i++)
        GitCommitSummary(
          oid: i == 0 ? 'main-oid' : 'c$i',
          parents: i < 23
              ? [i == 15 ? 'side-$i' : 'c${i + 1}']
              : const [],
          author: 'A',
          timestamp: 1700000000 - i,
          subject: 'commit $i',
        ),
    ];
    final api = DynamicMarginGitApi(commits);
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    final painter0 = find.byKey(const Key('git-graph-painter-main-oid'));
    expect(painter0, findsOneWidget);
    expect(tester.getSize(painter0).width, 80.0, reason: '首屏只有 lane0，最小宽 80');

    final vertical = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('git-graph-vertical')),
        matching: find.byType(Scrollable),
      ),
    );
    vertical.position.jumpTo(16 * kGitGraphRowHeight);
    // debounce 100ms 内不得换 target。
    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getSize(find.byKey(const Key('git-graph-painter-c16'))).width, 80.0,
        reason: 'debounce 期间宽度不变');
    await tester.pump(const Duration(milliseconds: 20));
    // debounce 后 150ms 平滑动画到 2 lanes = 30*2+32 = 92；中间帧应处于两值之间。
    await tester.pump(const Duration(milliseconds: 75));
    expect(
      tester.getSize(find.byKey(const Key('git-graph-painter-c16'))).width,
      inExclusiveRange(80.0, 92.0),
      reason: '150ms 动画中间帧不得瞬跳',
    );
    await tester.pump(const Duration(milliseconds: 105));
    final painter16 = find.byKey(const Key('git-graph-painter-c16'));
    expect(painter16, findsOneWidget);
    expect(tester.getSize(painter16).width, closeTo(92.0, 1.0),
        reason: 'merge 行可见时图宽=2 lane，且 150ms 内完成平滑');

    vertical.position.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.getSize(find.byKey(const Key('git-graph-painter-main-oid'))).width, 80.0,
        reason: '回滚后宽度恢复');
  });

  testWidgets('issue #102：横向 offset 在宽度变化后 clamp 且不跳左', (tester) async {
    final longName = 'refs/heads/${'x' * 180}';
    final commits = <GitCommitSummary>[
      for (var i = 0; i < 24; i++)
        if (i == 16)
          GitCommitSummary(
            oid: 'c$i',
            parents: const ['side-16'],
            author: 'A',
            timestamp: 1700000000 - i,
            subject: 'commit $i',
            decoration: GitDecoration(
              refs: [
                GitRefDetail(
                  kind: 'localBranch',
                  name: longName,
                  shortName: longName.substring('refs/heads/'.length),
                  oid: 'c16',
                ),
              ],
            ),
          )
        else
          GitCommitSummary(
            oid: i == 0 ? 'main-oid' : 'c$i',
            parents: i < 23 ? ['c${i + 1}'] : const [],
            author: 'A',
            timestamp: 1700000000 - i,
            subject: 'commit $i',
          ),
    ];
    final api = DynamicMarginGitApi(commits);
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    final horizontal = tester.state<ScrollableState>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable &&
            widget.axisDirection == AxisDirection.right,
      ),
    );
    horizontal.position.jumpTo(horizontal.position.maxScrollExtent);
    await tester.pump();
    final offsetBefore = horizontal.position.pixels;
    expect(offsetBefore, greaterThan(0));

    final vertical = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('git-graph-vertical')),
        matching: find.byType(Scrollable),
      ),
    );
    vertical.position.jumpTo(16 * kGitGraphRowHeight);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 180));
    expect(horizontal.position.pixels, closeTo(offsetBefore, 0.5),
        reason: '变宽不自动跳左');

    vertical.position.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 180));
    expect(horizontal.position.pixels, lessThanOrEqualTo(
        horizontal.position.maxScrollExtent + 0.5));
    expect(horizontal.position.pixels, greaterThan(0),
        reason: '变窄 clamp 到新 max，不重置 0');
  });

  testWidgets('issue #102：320/深色/1.5x 下动态边距与滚动不溢出', (tester) async {
    final commits = <GitCommitSummary>[
      for (var i = 0; i < 24; i++)
        GitCommitSummary(
          oid: i == 0 ? 'main-oid' : 'c$i',
          parents: i < 23 ? [i == 15 ? 'side-$i' : 'c${i + 1}'] : const [],
          author: 'A',
          timestamp: 1700000000 - i,
          subject: 'commit $i',
        ),
    ];
    final controller = await mountSheet(
      tester,
      DynamicMarginGitApi(commits),
      size: const Size(320, 640),
      theme: ThemeData.dark(),
      textScaler: const TextScaler.linear(1.5),
    );
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final vertical = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('git-graph-vertical')),
        matching: find.byType(Scrollable),
      ),
    );
    vertical.position.jumpTo(16 * 120);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.takeException(), isNull);
  });

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
    // issue #86：5/10 触顶不再只 toast——弹出三档快捷 sheet。
    expect(controller.state.selectedBranches.length, 5);
    expect(api.graphRequests.last.length, 5);
    expect(find.byKey(const Key('git-graph-limit-10')), findsOneWidget);
    expect(find.text('Select up to 5 branches'), findsNothing);

    await tester.tap(find.byKey(const Key('git-graph-limit-10')));
    await tester.pumpAndSettle();
    expect(controller.branchLimit, GitGraphBranchLimit.ten);
    // 升档保留选择 + 自动补选触发项（issue #86 产品定稿）。
    expect(controller.state.selectedBranches.length, 6);
    expect(api.graphRequests.last.length, 6);
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

  testWidgets('graph shows every ref and tag on one line without +N folding', (
    tester,
  ) async {
    const longRef =
        'feature/very-long-branch-name-that-would-have-been-ellipsized';
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();

    // 旧实现最多显示 2 个 + `+N`，且单个 pill 在 112px 处省略号截断。
    expect(find.text(longRef), findsOneWidget);
    expect(find.text('v2.0.0-rc.1'), findsOneWidget);
    expect(find.text('release-2026'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\+\d+$')), findsNothing);
    // 重复 ref 只出现一次；refs/stash 不展示。
    expect(find.text('feature'), findsOneWidget);
    expect(find.text('stash'), findsNothing);
    // 同一行（固定行高、单行标签）：所有 pill 纵向位置一致。
    final baseline = tester.getTopLeft(find.text(longRef)).dy;
    for (final text in ['feature', 'origin/main', 'v2.0.0-rc.1', 'release-2026']) {
      expect(tester.getTopLeft(find.text(text)).dy, baseline);
    }
    // 顺序：本地分支 → 远程分支 → tag。
    final featureX = tester.getTopLeft(find.text('feature')).dx;
    final remoteX = tester.getTopLeft(find.text('origin/main')).dx;
    final tagX = tester.getTopLeft(find.text('v2.0.0-rc.1')).dx;
    expect(featureX, lessThan(remoteX));
    expect(remoteX, lessThan(tagX));
  });

  testWidgets('commit detail renders structured refs and annotated tag metadata', (
    tester,
  ) async {
    final api = WidgetGitApi()..structuredDetails = true;
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-commit-main-oid')));
    await tester.pumpAndSettle();

    expect(find.text('Refs: main, feature, origin/main'), findsOneWidget);
    expect(
      find.text('Tags: v2.0, old (Tag targets a non-commit object)'),
      findsOneWidget,
    );
    expect(find.text('Tag details'), findsOneWidget);
    expect(find.text('Tagger: Release Bot'), findsOneWidget);
    expect(find.text('Release 2.0'), findsOneWidget);
  });

  testWidgets('commit detail shows none when refs and tags are empty', (
    tester,
  ) async {
    final api = WidgetGitApi()..emptyDetails = true;
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-commit-main-oid')));
    await tester.pumpAndSettle();

    expect(find.text('Refs: none'), findsOneWidget);
    expect(find.text('Tags: none'), findsOneWidget);
  });

  testWidgets('graph label viewport tracks system text scale without clipping', (
    tester,
  ) async {
    const longRef =
        'feature/very-long-branch-name-that-would-have-been-ellipsized';
    final api = WidgetGitApi();
    final controller = await mountSheet(tester, api);
    addTearDown(controller.dispose);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    expect(find.text(longRef), findsOneWidget);

    // 打开 sheet 后再改系统文字缩放：标签宽度缓存必须失效并重算，
    // 否则横向滚动范围会按旧字号计算导致裁切。
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();

    expect(find.text(longRef), findsOneWidget);
    expect(find.byKey(const Key('git-graph-horizontal')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
