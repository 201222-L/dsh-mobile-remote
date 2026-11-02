// 文件提交历史（issue #42）Widget 测试：tab/独立视图/深链/选择器/分页/空态。
import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:dsh_mobile_app/l10n.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/git_browser_sheet.dart';
import 'package:dsh_mobile_app/screens/session_files_screen.dart';
import 'package:dsh_mobile_app/session_files_controller.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _main = GitBranch(
  name: 'refs/heads/main',
  displayName: 'main',
  oid: 'main-oid',
  kind: 'local',
  current: true,
);

class HistoryGitApi implements GitReadApi {
  bool fileHistoryCapability = true;
  bool repositoryEmpty = false;
  bool failHistory = false;
  bool truncatedHistory = false;
  int pageOneCount = 2;
  bool failFiles = false;
  final Set<String> binaryPaths = {};

  final List<String?> fileQueries = [];
  final List<String?> historyPaths = [];
  final List<String?> historyCursors = [];

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async =>
      GitReadCapabilities(
        available: true,
        features: {
          'refsDetail': true,
          'fileHistory': fileHistoryCapability,
        },
      );

  @override
  Future<GitRepository> repository(String sessionId) async => GitRepository(
    repositoryId: 'repo-1',
    name: 'example',
    headOid: 'main-oid',
    currentBranch: 'refs/heads/main',
    empty: repositoryEmpty,
  );

  @override
  Future<List<GitBranch>> branches(
    String sessionId,
    String repositoryId,
  ) async => const [_main];

  @override
  Future<GitGraphPage> graph(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
  }) async => GitGraphPage(
    snapshotId: 'snapshot',
    tips: tips,
    commits: const [
      GitCommitSummary(
        oid: 'main-oid',
        subject: 'Main commit',
        author: 'Ada',
        timestamp: 1700000000,
      ),
    ],
  );

  @override
  Future<GitCommitDetails> commitDetails(
    String sessionId,
    String repositoryId,
    String oid, {
    String? filesCursor,
    int filesLimit = 100,
  }) async => GitCommitDetails(
    oid: oid,
    author: 'Ada',
    timestamp: 1700000000,
    message: 'History commit $oid',
    refs: const ['main'],
    files: const [GitCommitFile(path: 'lib/a.dart')],
    filesTotal: 1,
  );

  @override
  Future<GitWorktreeSnapshot> worktree(
    String sessionId,
    String repositoryId,
  ) async => const GitWorktreeSnapshot(
    repositoryId: 'repo-1',
    snapshotId: 'worktree-1',
    staged: [GitWorktreeFile(path: 'lib/a.dart', status: 'modified')],
    unstaged: [GitWorktreeFile(path: 'bad.txt', status: 'modified')],
    untracked: [GitWorktreeFile(path: 'new-file.txt', status: 'untracked')],
  );

  @override
  Future<GitFilePreview> preview(
    String sessionId,
    String repositoryId, {
    required String kind,
    required String path,
    String? snapshotId,
    String? oid,
  }) async => GitFilePreview(
    repositoryId: repositoryId,
    kind: kind,
    path: path,
    binary: binaryPaths.contains(path),
    diff:
        'diff --git a/$path b/$path\n@@ -1 +1 @@\n-old line\n+new line\n',
  );

  @override
  Future<GitFileList> files(
    String sessionId,
    String repositoryId, {
    String? q,
    int limit = 200,
  }) async {
    fileQueries.add(q);
    if (failFiles) throw ApiException('file list unavailable');
    const all = ['lib/a.dart', 'lib/b.dart', 'new-file.txt'];
    final query = (q ?? '').toLowerCase();
    return GitFileList(
      files: all
          .where((path) => query.isEmpty || path.toLowerCase().contains(query))
          .toList(),
    );
  }

  @override
  Future<GitFileHistoryPage> fileHistory(
    String sessionId,
    String repositoryId, {
    required String path,
    String? cursor,
    int limit = 20,
  }) async {
    historyPaths.add(path);
    historyCursors.add(cursor);
    if (failHistory) throw ApiException('history unavailable');
    if (path.contains('new-file')) {
      return GitFileHistoryPage(repositoryId: repositoryId, path: path, reason: 'not-tracked');
    }
    if (path.contains('bad')) {
      return GitFileHistoryPage(repositoryId: repositoryId, path: path, reason: 'path-invalid');
    }
    if (repositoryEmpty) {
      return GitFileHistoryPage(repositoryId: repositoryId, path: path, reason: 'no-history');
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (cursor != null) {
      return GitFileHistoryPage(
        repositoryId: repositoryId,
        path: path,
        entries: [
          GitFileHistoryEntry(
            oid: 'later-oid',
            shortOid: 'later-oi',
            author: 'Cyd',
            timestamp: now - 86400,
            subject: 'Delete c.dart',
            status: 'D',
          ),
        ],
      );
    }
    final entries = <GitFileHistoryEntry>[
      GitFileHistoryEntry(
        oid: 'aaaa111122223333',
        shortOid: 'aaaa1111',
        author: 'Ada',
        timestamp: now - 3600,
        subject: 'Update a.dart',
        status: 'M',
      ),
      if (pageOneCount > 1)
        GitFileHistoryEntry(
          oid: 'bbbb222233334444',
          shortOid: 'bbbb2222',
          author: 'Bob',
          timestamp: now - 7200,
          subject: 'Add b.dart',
          status: 'A',
        ),
      for (var i = 2; i < pageOneCount; i++)
        GitFileHistoryEntry(
          oid: 'oid-$i',
          shortOid: 'short-$i',
          author: 'Ada',
          timestamp: now - 7200 - i,
          subject: 'History $i',
          status: 'M',
        ),
    ];
    return GitFileHistoryPage(
      repositoryId: repositoryId,
      path: path,
      entries: entries,
      nextCursor: truncatedHistory ? null : 'cursor-2',
      truncated: truncatedHistory,
    );
  }
}

AppStore makeStore() {
  final store = AppStore();
  store.sessionId = 'session-1';
  store.sessions = [
    Session(id: 'session-1', title: 'Test', cwd: '/work', createdAt: 0),
  ];
  return store;
}

Future<GitBrowserController> mountSheet(
  WidgetTester tester,
  HistoryGitApi api, {
  List<String> tabs = const ['branches', 'graph', 'worktree'],
  bool pushed = false,
}) async {
  final controller = GitBrowserController(api);
  addTearDown(controller.dispose);
  final graphScroll = ScrollController();
  addTearDown(graphScroll.dispose);
  await controller.open('session-1');
  final sheet = GitBrowserSheet(
    controller: controller,
    scrollController: graphScroll,
    tabs: tabs,
  );
  if (!pushed) {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(height: 700, child: sheet)),
      ),
    );
  } else {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: Center(child: Text('host page'))),
      ),
    );
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => sheet),
      ),
    );
  }
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _expectClipboard(
  WidgetTester tester,
  Future<void> Function() action,
  String expected,
) async {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      calls.add(call);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  await action();
  await tester.pumpAndSettle();
  final clipboard = calls.where((call) => call.method == 'Clipboard.setData');
  expect(clipboard, hasLength(1));
  expect((clipboard.single.arguments as Map)['text'], expected);
}

void main() {
  setUp(() {
    L10n.lang = 'en';
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => L10n.lang = 'zh');

  testWidgets('history tab is optional and does not appear by default', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api);
    expect(find.text('Branches'), findsOneWidget);
    expect(find.text('History'), findsNothing);
  });

  testWidgets('history tab auto-opens the picker once and cancel keeps empty state', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(
      tester,
      api,
      tabs: const ['branches', 'graph', 'fileHistory'],
    );
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();

    // 未选择文件：引导空态 + 自动打开一次选择器。
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-history-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsNothing);
    expect(find.byKey(const Key('git-history-empty')), findsOneWidget);
    expect(
      find.text('Choose a file to see its commit history'),
      findsOneWidget,
    );

    // 切走再切回：不再自动打开（一次 per surface）。
    await tester.tap(find.text('Branches'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsNothing);
    expect(find.byKey(const Key('git-history-empty')), findsOneWidget);
  });

  testWidgets('picker searches server-side with a 250ms debounce', (tester) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, tabs: const ['fileHistory']);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
    expect(api.fileQueries, [null]);

    await tester.enterText(find.byKey(const Key('git-history-search')), 'b.');
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.fileQueries, [null], reason: '防抖期间不请求');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(api.fileQueries, [null, 'b.']);
    expect(find.byKey(const Key('git-history-file-lib/b.dart')), findsOneWidget);
    expect(find.byKey(const Key('git-history-file-lib/a.dart')), findsNothing);

    await tester.tap(find.byKey(const Key('git-history-file-lib/b.dart')));
    await tester.pumpAndSettle();
    expect(api.historyPaths, ['lib/b.dart']);
    expect(find.text('Update a.dart'), findsOneWidget);

    // 最近使用按仓库记录，重新打开选择器即可一键复选。
    await tester.tap(find.byKey(const Key('git-history-change')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('git-history-search')), '');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('git-history-recent-lib/b.dart')),
      findsOneWidget,
    );
  });

  testWidgets('history rows show metadata, status and open existing commit detail', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, tabs: const ['fileHistory'], pushed: true);
    await tester.tap(find.byKey(const Key('git-history-file-lib/a.dart')));
    await tester.pumpAndSettle();

    expect(find.text('Update a.dart'), findsOneWidget);
    expect(find.textContaining('aaaa1111'), findsOneWidget);
    expect(find.textContaining('Ada'), findsWidgets);
    expect(find.textContaining('1 hr ago'), findsOneWidget);
    expect(
      find.byKey(const Key('git-history-status-aaaa111122223333')),
      findsOneWidget,
    );
    expect(find.text('A'), findsOneWidget); // 第二行状态徽标

    await _expectClipboard(
      tester,
      () => tester.longPress(
        find.byKey(const Key('git-history-row-aaaa111122223333')),
      ),
      'aaaa111122223333',
    );

    await tester.tap(
      find.byKey(const Key('git-history-row-aaaa111122223333')),
    );
    await tester.pumpAndSettle();
    expect(find.text('History commit aaaa111122223333'), findsOneWidget);
    expect(find.text('Commit details'), findsOneWidget);

    // 从历史打开详情后，返回回到历史列表。
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);
  });

  testWidgets('history pagination loads the next page near the bottom', (
    tester,
  ) async {
    final api = HistoryGitApi()..pageOneCount = 20;
    await mountSheet(tester, api, tabs: const ['fileHistory']);
    await tester.tap(find.byKey(const Key('git-history-file-lib/a.dart')));
    await tester.pumpAndSettle();
    expect(api.historyCursors, [null]);

    await tester.drag(
      find.byKey(const Key('git-history-list')),
      const Offset(0, -2400),
    );
    await tester.pumpAndSettle();

    expect(api.historyCursors, [null, 'cursor-2']);
    expect(find.text('Delete c.dart'), findsOneWidget);
  });

  testWidgets('deep link builds a standalone history view without a tab bar', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-file-preview')), findsOneWidget);

    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('File history'), findsOneWidget);
    expect(find.text('Update a.dart'), findsOneWidget);

    // 返回恢复原查看器状态（同一份 diff 预览）。
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-file-preview')), findsOneWidget);
    expect(find.text('Update a.dart'), findsNothing);
    expect(find.text('new line'), findsOneWidget);
  });

  testWidgets('deep link switches to the history tab when it is configured', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(
      tester,
      api,
      tabs: const ['branches', 'worktree', 'fileHistory'],
      pushed: true,
    );
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();

    // 已启用 history tab：切换过去，TabBar 仍在。
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.text('Update a.dart'), findsOneWidget);
    expect(find.byKey(const Key('git-history-picker')), findsNothing);
  });

  testWidgets('file history action is hidden without the capability', (
    tester,
  ) async {
    final api = HistoryGitApi()..fileHistoryCapability = false;
    await mountSheet(tester, api);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-file-history')), findsNothing);
  });

  testWidgets('history tab explains unsupported hosts', (tester) async {
    final api = HistoryGitApi()..fileHistoryCapability = false;
    await mountSheet(tester, api, tabs: const ['branches', 'fileHistory']);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(
      find.text('File history is not supported by this host'),
      findsOneWidget,
    );
  });

  testWidgets('untracked and invalid-path files show clear empty states', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, pushed: true);

    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-untracked-new-file.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(
      find.text('No commit history (untracked file)'),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('git-worktree-unstaged-bad.txt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(
      find.text('Path is outside the repository or is not a file'),
      findsOneWidget,
    );
    expect(find.text('Choose another file'), findsOneWidget);
  });

  testWidgets('empty repositories and truncated histories are explained', (
    tester,
  ) async {
    final api = HistoryGitApi()
      ..repositoryEmpty = true
      ..truncatedHistory = true;
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    // 空仓库优先给出「仓库还没有提交」。
    expect(find.text('Repository has no commits'), findsOneWidget);
  });

  testWidgets('truncated history shows latest-N note', (tester) async {
    final api = HistoryGitApi()..truncatedHistory = true;
    await mountSheet(tester, api, tabs: const ['fileHistory']);
    await tester.tap(find.byKey(const Key('git-history-file-lib/a.dart')));
    await tester.pumpAndSettle();
    expect(find.text('Showing latest 2 commits'), findsOneWidget);
  });

  testWidgets('history network errors expose retry', (tester) async {
    final api = HistoryGitApi()..failHistory = true;
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(find.text('history unavailable'), findsOneWidget);

    api.failHistory = false;
    await tester.tap(find.byKey(const Key('git-history-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);
  });

  testWidgets('session files viewer opens the shared history surface', (
    tester,
  ) async {
    final api = HistoryGitApi();
    final fileApi = Api(
      client: MockClient((request) async {
        final path = request.url.queryParameters['path'] ?? '';
        if (request.url.path == '/m/api/directories') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'path': path,
              'dirs': <String>[],
              'files': ['README.md'],
            }),
            200,
          );
        }
        if (request.url.path == '/m/api/files') {
          return http.Response.bytes(utf8.encode('line one\nline two\n'), 200);
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    )
      ..baseUrl = 'http://sf.test'
      ..path = '/m'
      ..token = '';
    final store = makeStore();
    final controller = SessionFilesController(
      store: store,
      sessionId: 'session-1',
      apiClient: fileApi,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SessionFilesScreen(
          store: store,
          sessionId: 'session-1',
          controller: controller,
          gitReadApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sf-file-README.md')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-history')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sf-history')));
    await tester.pumpAndSettle();
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Update a.dart'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-preview')), findsOneWidget);
    expect(find.textContaining('line one'), findsOneWidget);
  });

  testWidgets('session files hides the history action without capability', (
    tester,
  ) async {
    final api = HistoryGitApi()..fileHistoryCapability = false;
    final fileApi = Api(
      client: MockClient((request) async {
        final path = request.url.queryParameters['path'] ?? '';
        if (request.url.path == '/m/api/directories') {
          return http.Response(
            jsonEncode({
              'ok': true,
              'path': path,
              'dirs': <String>[],
              'files': ['README.md'],
            }),
            200,
          );
        }
        if (request.url.path == '/m/api/files') {
          return http.Response.bytes(utf8.encode('line one\n'), 200);
        }
        return http.Response('unexpected ${request.url}', 500);
      }),
    )
      ..baseUrl = 'http://sf.test'
      ..path = '/m'
      ..token = '';
    final store = makeStore();
    final controller = SessionFilesController(
      store: store,
      sessionId: 'session-1',
      apiClient: fileApi,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SessionFilesScreen(
          store: store,
          sessionId: 'session-1',
          controller: controller,
          gitReadApi: api,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sf-file-README.md')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sf-history')), findsNothing);
  });

  testWidgets('binary and untracked-binary previews keep the history action', (
    tester,
  ) async {
    final api = HistoryGitApi()
      ..binaryPaths.addAll(['lib/a.dart', 'new-file.txt']);
    await mountSheet(tester, api, pushed: true);

    // 二进制 staged 文件：预览不可读，但查看器头栏仍保留历史入口。
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('git-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('git-file-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);

    // 返回预览，再返回工作区。
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // 未跟踪二进制文件：入口可见，进入后给出 not-tracked 空态。
    await tester.tap(
      find.byKey(const Key('git-worktree-untracked-new-file.txt')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('git-file-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(find.text('No commit history (untracked file)'), findsOneWidget);
  });
}
