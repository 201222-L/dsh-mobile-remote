// 文件提交历史（issue #42）Widget 测试：tab/独立视图/深链/选择器/分页/空态。
import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
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

import 'git_history_fake.dart';

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
  Future<String?> Function(BuildContext context, String sessionId)?
  fileBrowserPicker,
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
    fileBrowserPicker: fileBrowserPicker,
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
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => sheet)),
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

  testWidgets(
    'history tab auto-opens the picker once and cancel keeps empty state',
    (tester) async {
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
    },
  );

  testWidgets('picker searches server-side with a 250ms debounce', (
    tester,
  ) async {
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
    expect(
      find.byKey(const Key('git-history-file-lib/b.dart')),
      findsOneWidget,
    );
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

  testWidgets(
    'history rows show metadata/status and open the file diff at that commit',
    (tester) async {
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

      // A) 直接打开该文件在该提交上的 diff（kind=commit/path=selectedPath/oid=行 oid），
      //    不经过通用提交详情。
      expect(api.previews.last.kind, 'commit');
      expect(api.previews.last.path, 'lib/a.dart');
      expect(api.previews.last.oid, 'aaaa111122223333');
      expect(find.byKey(const Key('git-file-preview')), findsOneWidget);
      expect(find.text('new line'), findsOneWidget);
      expect(find.text('History commit aaaa111122223333'), findsNothing);
      expect(find.text('Commit details'), findsNothing);

      // C) 历史来源的 diff 返回原位历史 surface（这里是 fileHistory tab 根）。
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Update a.dart'), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);
    },
  );

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

    // B) 独立历史视图的返回直接退出 Git 浏览器到调用方，不恢复进入前的预览。
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('host page'), findsOneWidget);
    expect(find.byType(GitBrowserSheet), findsNothing);
    expect(find.byKey(const Key('git-file-preview')), findsNothing);
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

    // 设计决策：tab 模式下返回键与手动切 tab 一致——在 tab 根退出 Git 浏览器，
    // 而不是恢复进入前的 diff 预览（独立历史视图才恢复预览）。
    await tester.tap(find.byTooltip('Back to chat'));
    await tester.pumpAndSettle();
    expect(find.text('host page'), findsOneWidget);
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

  testWidgets('untracked files show a clear not-tracked empty state', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, pushed: true);

    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('git-worktree-untracked-new-file.txt')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(
      find.text('File is not in the current HEAD (untracked or deleted)'),
      findsOneWidget,
    );
  });

  testWidgets('outside-repo/invalid path shows an error with reselect', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, pushed: true);

    await tester.tap(find.text('Worktree'));
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
    final fileApi =
        Api(
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
                return http.Response.bytes(
                  utf8.encode('line one\nline two\n'),
                  200,
                );
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
    final fileApi =
        Api(
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

  testWidgets('binary worktree preview keeps the history action', (
    tester,
  ) async {
    final api = HistoryGitApi()..binaryPaths.add('lib/a.dart');
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();

    // 二进制 staged 文件：预览不可读，但查看器头栏仍保留历史入口。
    expect(find.byKey(const Key('git-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('git-file-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);
    expect(api.historyPaths, ['lib/a.dart']);
  });

  testWidgets('untracked binary preview opens the not-tracked history state', (
    tester,
  ) async {
    final api = HistoryGitApi()..binaryPaths.add('new-file.txt');
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('git-worktree-untracked-new-file.txt')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('git-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('git-file-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(
      find.text('File is not in the current HEAD (untracked or deleted)'),
      findsOneWidget,
    );
  });

  testWidgets('picker cancel then reopen resets the stale query', (
    tester,
  ) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, tabs: const ['fileHistory']);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('git-history-search')), 'b.');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.fileQueries.last, 'b.');

    await tester.tap(find.byKey(const Key('git-history-cancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-history-change')));
    await tester.pumpAndSettle();

    // 重开选择器：输入框与结果都不能残留上次搜索词。
    final field = tester.widget<TextField>(
      find.byKey(const Key('git-history-search')),
    );
    expect(field.controller!.text, isEmpty);
    expect(api.fileQueries.last, isNull);
    expect(
      find.byKey(const Key('git-history-file-lib/a.dart')),
      findsOneWidget,
    );
  });

  testWidgets('history rows render C/T/unknown status badges', (tester) async {
    final api = HistoryGitApi()..statusesOverride = ['C', 'T', 'Z'];
    await mountSheet(tester, api, tabs: const ['fileHistory']);
    await tester.tap(find.byKey(const Key('git-history-file-lib/a.dart')));
    await tester.pumpAndSettle();

    expect(find.text('C'), findsOneWidget);
    expect(find.text('T'), findsOneWidget);
    expect(find.text('Z'), findsOneWidget);
    expect(
      find.byKey(const Key('git-history-status-status-oid-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('git-history-status-status-oid-2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('notice preview keeps the history action reachable', (
    tester,
  ) async {
    final api = HistoryGitApi()..noticePaths.add('lib/a.dart');
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('git-unavailable')), findsOneWidget);
    expect(find.text('preview unavailable'), findsOneWidget);
    expect(find.byKey(const Key('git-file-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);
  });

  testWidgets('commit-diff origin with binary preview keeps history action', (
    tester,
  ) async {
    final api = HistoryGitApi()..binaryPaths.add('lib/a.dart');
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-commit-main-oid')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-file-lib/a.dart')));
    await tester.pumpAndSettle();

    // commit diff origin + binary preview：历史入口仍可达并可打开历史。
    expect(find.byKey(const Key('git-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('git-file-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-file-history')));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);
    expect(api.historyPaths, ['lib/a.dart']);
  });

  testWidgets(
    'independent history -> diff -> history does not loop; back exits',
    (tester) async {
      final api = HistoryGitApi();
      await mountSheet(tester, api, pushed: true);
      await tester.tap(find.text('Worktree'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-file-history')));
      await tester.pumpAndSettle();
      expect(find.text('Update a.dart'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);

      // 历史行 → 直接 diff；返回回到独立历史视图（不回到进入前的 worktree 预览）。
      await tester.tap(
        find.byKey(const Key('git-history-row-aaaa111122223333')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('git-file-preview')), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Update a.dart'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);

      // D) 历史来源 diff 里的「提交历史」回到同一个独立历史 surface，不叠加路由。
      await tester.tap(
        find.byKey(const Key('git-history-row-aaaa111122223333')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-file-history')));
      await tester.pumpAndSettle();
      expect(find.text('Update a.dart'), findsOneWidget);
      expect(find.byType(GitBrowserSheet), findsOneWidget);

      // B) 独立历史返回直接退出 Git 浏览器，循环终止。
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('host page'), findsOneWidget);
      expect(find.byType(GitBrowserSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tab-enabled history-origin diff back returns to the history tab',
    (tester) async {
      final api = HistoryGitApi();
      await mountSheet(
        tester,
        api,
        tabs: const ['branches', 'fileHistory'],
        pushed: true,
      );
      await tester.tap(find.text('History'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-history-file-lib/a.dart')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('git-history-row-aaaa111122223333')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('git-file-preview')), findsOneWidget);

      // C) 返回原位 history tab（TabBar 恢复、历史列表仍在）。
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Update a.dart'), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);

      // tab 根返回退出 Git 浏览器。
      await tester.tap(find.byTooltip('Back to chat'));
      await tester.pumpAndSettle();
      expect(find.text('host page'), findsOneWidget);
    },
  );

  testWidgets('worktree preview back returns to the tab', (tester) async {
    final api = HistoryGitApi();
    await mountSheet(tester, api, pushed: true);
    await tester.tap(find.text('Worktree'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('git-worktree-staged-lib/a.dart')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-file-preview')), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Staged (1)'), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
  });

  testWidgets(
    'commit-detail file preview back still returns to commit detail',
    (tester) async {
      final api = HistoryGitApi();
      await mountSheet(tester, api, pushed: true);
      await tester.tap(find.byKey(const Key('git-branch-refs/heads/main')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-commit-main-oid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('git-file-lib/a.dart')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('git-file-preview')), findsOneWidget);

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Commit details'), findsOneWidget);
      expect(find.byKey(const Key('git-file-preview')), findsNothing);
    },
  );

  testWidgets('session files hides history when capability probe fails', (
    tester,
  ) async {
    final api = HistoryGitApi()..failCapabilities = true;
    final fileApi =
        Api(
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
    // 探测失败（旧宿主/非仓库）：入口隐藏，文件浏览不受影响。
    expect(find.byKey(const Key('sf-history')), findsNothing);
    expect(find.byKey(const Key('sf-preview')), findsOneWidget);
  });

  testWidgets('session files binary preview keeps the history action', (
    tester,
  ) async {
    final api = HistoryGitApi();
    final fileApi =
        Api(
            client: MockClient((request) async {
              final path = request.url.queryParameters['path'] ?? '';
              if (request.url.path == '/m/api/directories') {
                return http.Response(
                  jsonEncode({
                    'ok': true,
                    'path': path,
                    'dirs': <String>[],
                    'files': ['photo.png'],
                  }),
                  200,
                );
              }
              if (request.url.path == '/m/api/files') {
                return http.Response.bytes([0x89, 0x50, 0x00, 0x4E], 200);
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
    await tester.tap(find.byKey(const Key('sf-file-photo.png')));
    await tester.pumpAndSettle();

    // 会话文件页的二进制不可预览态：leading/历史入口仍保留。
    expect(find.byKey(const Key('sf-preview-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('sf-preview-back')), findsOneWidget);
    expect(find.byKey(const Key('sf-history')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sf-history')));
    await tester.pumpAndSettle();
    expect(find.text('Update a.dart'), findsOneWidget);
  });

  testWidgets(
    'injected file browser selects a file and loads history in place',
    (tester) async {
      final api = HistoryGitApi();
      final picks = <String>[];
      await mountSheet(
        tester,
        api,
        tabs: const ['fileHistory'],
        fileBrowserPicker: (context, sessionId) async {
          picks.add(sessionId);
          return 'lib/a.dart';
        },
      );
      await tester.pumpAndSettle();
      // 无文件时仍先自动打开内联选择器一次（不自动打开全屏浏览器）。
      expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('git-history-cancel')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('git-history-change')));
      await tester.pumpAndSettle();

      expect(picks, ['session-1']);
      expect(find.text('Update a.dart'), findsOneWidget);
      expect(api.historyPaths, ['lib/a.dart']);
      // 选择后仍停留在原历史视图，没有叠加第二个 GitBrowserSheet。
      expect(find.byType(GitBrowserSheet), findsOneWidget);
    },
  );

  testWidgets('file browser cancel leaves the history selection unchanged', (
    tester,
  ) async {
    final api = HistoryGitApi();
    var browseCalls = 0;
    await mountSheet(
      tester,
      api,
      tabs: const ['fileHistory'],
      fileBrowserPicker: (context, sessionId) async {
        browseCalls++;
        return null;
      },
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('git-history-picker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('git-history-cancel')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('git-history-change')));
    await tester.pumpAndSettle();

    expect(browseCalls, 1);
    expect(api.historyPaths, isEmpty);
    expect(find.byKey(const Key('git-history-empty')), findsOneWidget);
    expect(find.byKey(const Key('git-history-picker')), findsNothing);
  });
}
