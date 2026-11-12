/// issue #93：全部分支图（all=true）+ focus 定位 + 双向分页。
import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:dsh_mobile_app/screens/git_browser_sheet.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _allCaps = GitReadCapabilities(
  available: true,
  features: {'graph': true, 'refsDetail': true},
  graphTipsMax: 128,
  graphTipsGetMax: 32,
  graphAllPageSize: 16,
  graphAllMaxRefs: 4096,
  graphAllMaxScan: 5000,
);

const _legacyCaps = GitReadCapabilities(
  available: true,
  features: {'graph': true},
  graphTipsMax: 128,
  graphTipsGetMax: 32,
);

const _repo = GitRepository(
  repositoryId: 'repo',
  name: 'project',
  headOid: 'head',
  currentBranch: 'refs/heads/develop',
);

const _branches = [
  GitBranch(name: 'refs/heads/develop', displayName: 'develop', oid: 'head', kind: 'local', current: true),
  GitBranch(name: 'refs/remotes/origin/main', displayName: 'origin/main', oid: 'remote', kind: 'remote'),
];

GitCommitSummary _commit(String oid, [String subject = 'commit']) =>
    GitCommitSummary(oid: oid, subject: subject);

GitGraphPage _page({
  required List<String> oids,
  String? snapshotId = 'snap-1',
  String? nextCursor,
  String? prevCursor,
  String? focusOid,
  int pageStart = 0,
  bool all = true,
}) => GitGraphPage(
  commits: [for (final oid in oids) _commit(oid, 'subject $oid')],
  snapshotId: snapshotId,
  nextCursor: nextCursor,
  prevCursor: prevCursor,
  all: all,
  pageSize: 16,
  pageStart: pageStart,
  focusOid: focusOid,
  hasNewer: pageStart > 0,
  hasOlder: nextCursor != null,
);

class _FakeGitApi implements GitReadApi, GitGraphPostApi, GitGraphAllApi {
  _FakeGitApi({this.capabilitiesValue = _allCaps});

  final GitReadCapabilities capabilitiesValue;
  int allCalls = 0;
  int graphCalls = 0;
  final List<Map<String, Object?>> requests = [];
  Future<GitGraphPage> Function(String? focus, String? snapshotId, String? cursor)? onAll;

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async => capabilitiesValue;
  @override
  Future<GitRepository> repository(String sessionId) async => _repo;
  @override
  Future<List<GitBranch>> branches(String sessionId, String repositoryId) async => _branches;

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
    graphCalls += 1;
    return _page(oids: ['legacy'], all: false);
  }

  @override
  Future<GitGraphPage> graphPost(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    graphCalls += 1;
    return _page(oids: ['legacy-post'], all: false);
  }

  @override
  Future<GitGraphPage> graphAll(
    String sessionId,
    String repositoryId, {
    required bool all,
    String? focus,
    String? snapshotId,
    String? cursor,
    int limit = 16,
    Duration timeout = const Duration(seconds: 35),
  }) async {
    allCalls += 1;
    requests.add({'all': all, 'focus': focus, 'snapshotId': snapshotId, 'cursor': cursor, 'limit': limit});
    return onAll != null
        ? onAll!(focus, snapshotId, cursor)
        : _page(oids: ['c1', 'c2'], focusOid: 'c1');
  }

  @override
  Future<GitCommitDetails> commitDetails(String sessionId, String repositoryId, String oid, {String? filesCursor, int filesLimit = 100}) =>
      throw UnimplementedError();
  @override
  Future<GitWorktreeSnapshot> worktree(String sessionId, String repositoryId) => throw UnimplementedError();
  @override
  Future<GitFilePreview> preview(String sessionId, String repositoryId, {required String kind, required String path, String? snapshotId, String? oid}) =>
      throw UnimplementedError();
  @override
  Future<GitFileList> files(String sessionId, String repositoryId, {String? q, int limit = 200}) => throw UnimplementedError();
  @override
  Future<GitFileHistoryPage> fileHistory(String sessionId, String repositoryId, {required String path, String? cursor, int limit = 20}) =>
      throw UnimplementedError();
}

void main() {
  group('issue #93 controller：all 模式', () {
    test('不限档 + host graphAll → all 模式；首屏 focus 当前分支/16 页', () async {
      final api = _FakeGitApi();
      final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
      await controller.open('session-a');
      expect(controller.graphAllMode, isTrue);
      await controller.openAllGraph();
      expect(api.allCalls, 1);
      expect(api.requests.single, {
        'all': true,
        'focus': 'refs/heads/develop',
        'snapshotId': null,
        'cursor': null,
        'limit': 16,
      });
      expect(controller.state.graphAll, isTrue);
      expect(controller.state.graphFocusOid, 'c1');
      expect(controller.state.graphPageStart, 0);
    });

    test('焦点页非第一页：prev 追加更新页（前插）、next 追加更旧页（后插），去重', () async {
      final pages = <String, GitGraphPage>{
        'focus': _page(oids: ['c10', 'c11'], snapshotId: 's', prevCursor: 'p1', nextCursor: 'n1', focusOid: 'c10', pageStart: 32),
        'prev': _page(oids: ['c8', 'c9'], snapshotId: 's', nextCursor: 'n2', pageStart: 16),
        'next': _page(oids: ['c12', 'c13'], snapshotId: 's', prevCursor: 'p2', pageStart: 48),
      };
      final api = _FakeGitApi()
        ..onAll = (focus, snapshotId, cursor) async {
          if (snapshotId == null) return pages['focus']!;
          return cursor == 'p1' ? pages['prev']! : pages['next']!;
        };
      final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
      await controller.open('session-a');
      await controller.openAllGraph();
      expect(controller.state.commits.map((commit) => commit.oid), ['c10', 'c11']);
      await controller.loadPrevGraphPage();
      expect(controller.state.commits.map((commit) => commit.oid), ['c8', 'c9', 'c10', 'c11']);
      await controller.loadNextGraphPage();
      expect(controller.state.commits.map((commit) => commit.oid), ['c8', 'c9', 'c10', 'c11', 'c12', 'c13']);
      expect(controller.state.commits.map((commit) => commit.oid).toSet().length, 6, reason: '跨页无重复');
    });

    test('409 stale：保留已加载页并置 stale，不替换整图', () async {
      var calls = 0;
      final api = _FakeGitApi()
        ..onAll = (focus, snapshotId, cursor) async {
          calls += 1;
          if (calls == 1) return _page(oids: ['c1', 'c2'], nextCursor: 'n1');
          throw ApiException('stale', code: 'graph-stale', status: 409);
        };
      final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
      await controller.open('session-a');
      await controller.openAllGraph();
      expect(controller.state.commits, hasLength(2));
      await controller.loadNextGraphPage();
      expect(controller.state.commits, hasLength(2), reason: 'stale 不丢弃已加载页');
      expect(controller.state.stale, isTrue);
      expect(controller.state.error, 'graph-stale');
    });

    test('旧宿主无 graphAll → 不限档仍走原选择集（不进入 all 模式）', () async {
      final api = _FakeGitApi(capabilitiesValue: _legacyCaps);
      final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
      await controller.open('session-a');
      expect(controller.graphAllMode, isFalse);
    });
  });

  test('issue #93 API：graphAll 只发 POST all=true/focus/limit，并解析 prev/focus 字段', () async {
    late Map<String, dynamic> body;
    late String method;
    final api = Api(client: MockClient((request) async {
      method = request.method;
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({
        'commits': [{'oid': 'focused', 'subject': 'focus'}],
        'snapshotId': 'snap',
        'nextCursor': 'next',
        'prevCursor': 'prev',
        'all': true,
        'pageSize': 16,
        'pageStart': 32,
        'focusOid': 'focused',
      }), 200, headers: {'content-type': 'application/json'});
    }))
      ..baseUrl = 'http://git93.test'
      ..path = '/m'
      ..token = '';
    final page = await api.graphAll('s', 'r', all: true, focus: 'refs/heads/develop');
    expect(method, 'POST');
    expect(body['all'], true);
    expect(body['focus'], 'refs/heads/develop');
    expect(body['limit'], 16);
    expect(body.containsKey('tips'), isFalse);
    expect(page.all, isTrue);
    expect(page.prevCursor, 'prev');
    expect(page.focusOid, 'focused');
    expect(page.pageStart, 32);
  });

  testWidgets('issue #93 widget：all 模式隐藏筛选/全选并显示全部分支标签', (tester) async {
    final api = _FakeGitApi();
    final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
    final store = AppStore()..gitGraphBranchLimit = GitGraphBranchLimit.unlimited;
    final scroll = ScrollController();
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
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
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('git-graph-all-label')), findsOneWidget);
    expect(find.byKey(const Key('git-graph-filter')), findsNothing);
    expect(find.byKey(const Key('git-graph-select-all')), findsNothing);
    expect(find.byKey(const Key('git-graph-empty-selection')), findsNothing);
    expect(api.allCalls, greaterThanOrEqualTo(1));
    controller.dispose();
    scroll.dispose();
  });

  testWidgets('issue #93 widget：focus 初始页自动滚到 focus 行', (tester) async {
    final oids = [for (var index = 0; index < 16; index += 1) 'c$index'];
    final api = _FakeGitApi()
      ..onAll = (focus, snapshotId, cursor) async =>
          _page(oids: oids, focusOid: 'c8', pageStart: 32);
    final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
    final store = AppStore()..gitGraphBranchLimit = GitGraphBranchLimit.unlimited;
    final scroll = ScrollController();
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GitBrowserSheet(controller: controller, scrollController: scroll, tabs: const ['graph'], store: store),
      ),
    ));
    await controller.open('session-a');
    await tester.pumpAndSettle();
    // 8 * kGitGraphRowHeight(86)，受 maxScrollExtent 限制。
    final expected = (8 * kGitGraphRowHeight).clamp(0.0, scroll.position.maxScrollExtent);
    expect(scroll.offset, closeTo(expected, 1.0), reason: 'focus 行必须滚入视口');
    expect(controller.state.graphFocusOid, 'c8');
    controller.dispose();
    scroll.dispose();
  });

  testWidgets('issue #93 widget：向上加载 prev 页后当前可见 commit 不跳', (tester) async {
    final initial = [for (var index = 0; index < 16; index += 1) 'c$index'];
    final newer = ['n0', 'n1'];
    final api = _FakeGitApi()
      ..onAll = (focus, snapshotId, cursor) async {
        if (snapshotId == null) {
          return _page(oids: initial, focusOid: 'c0', pageStart: 32, prevCursor: 'p1', nextCursor: 'n1');
        }
        return _page(oids: newer, snapshotId: 'snap-1', pageStart: 16, nextCursor: 'n2');
      };
    final controller = GitBrowserController(api, branchLimit: GitGraphBranchLimit.unlimited);
    final store = AppStore()..gitGraphBranchLimit = GitGraphBranchLimit.unlimited;
    final scroll = ScrollController();
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GitBrowserSheet(controller: controller, scrollController: scroll, tabs: const ['graph'], store: store),
      ),
    ));
    await controller.open('session-a');
    // 首屏在顶部且 prevCursor 存在 → 自动预取更新页（真实滚动监听同一路径）。
    await tester.pumpAndSettle();
    final beforeFirstVisible = 'c0';
    expect(controller.state.commits.take(2).map((commit) => commit.oid), newer);
    // 前插 2 行后滚动补偿 2*rowHeight：原来顶部那行仍在顶部可见。
    expect(scroll.offset, closeTo(newer.length * kGitGraphRowHeight, 1.0));
    final topIndex = (scroll.offset / kGitGraphRowHeight).round();
    expect(controller.state.commits[topIndex].oid, beforeFirstVisible,
        reason: '前插后当前可见 commit 必须保持不变');
    controller.dispose();
    scroll.dispose();
  });
}
