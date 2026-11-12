// issue #86：Git 分支图选中上限三档（5/10/不限）——纯逻辑与 controller 回归。
//
// 覆盖：档位解析/默认/持久化、5/10 触顶拒绝、unlimited 不设硬上限、
// 升档保留/降档裁剪前 N、全选只作用于传入的当前搜索结果、清空、
// 16 色 palette（10 档不撞色、>16 循环）。

import 'dart:async';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_graph_logic.dart';
import 'package:dsh_mobile_app/git_graph_presentation.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<GitBranch> _branches(int count) => [
  for (var i = 0; i < count; i++)
    GitBranch(
      name: 'refs/heads/b$i',
      displayName: 'b$i',
      oid: 'oid-$i',
      kind: 'local',
    ),
];

class _FakeGitApi implements GitReadApi {
  _FakeGitApi({this.branchCount = 12});

  final int branchCount;
  final List<List<String>> graphTips = [];
  Completer<GitGraphPage>? graphGate;
  bool queueGates = false;
  final List<Completer<GitGraphPage>> pendingGates = [];

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async =>
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
      _branches(branchCount);

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
    graphTips.add(tips.map((tip) => tip.name).toList());
    if (queueGates) {
      final gate = Completer<GitGraphPage>();
      pendingGates.add(gate);
      return gate.future;
    }
    if (graphGate != null) return graphGate!.future;
    return Future.value(
      GitGraphPage(snapshotId: 'snapshot', nextCursor: null, tips: tips),
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

/// task-28：GET/POST 双传输 fake（实现可选 GitGraphPostApi）。
class _TransportApi extends _FakeGitApi implements GitGraphPostApi {
  _TransportApi({super.branchCount = 160, this.capsOverride});
  final GitReadCapabilities? capsOverride;
  int getCalls = 0;
  int postCalls = 0;
  bool failGet431Once = false;
  Object? postError;

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async =>
      capsOverride ??
      const GitReadCapabilities(
        available: true,
        graphTipsMax: 128,
        graphTipsGetMax: 32,
      );

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
    getCalls += 1;
    if (failGet431Once) {
      failGet431Once = false;
      throw ApiException('request header fields too large', status: 431);
    }
    graphTips.add(tips.map((tip) => tip.name).toList());
    return Future.value(
      GitGraphPage(snapshotId: 'get', nextCursor: null, tips: tips),
    );
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
  }) {
    postCalls += 1;
    graphTips.add(tips.map((tip) => tip.name).toList());
    final error = postError;
    if (error != null) return Future.error(error);
    return Future.value(
      GitGraphPage(snapshotId: 'post', nextCursor: null, tips: tips),
    );
  }
}

List<GitBranch> _namedBranches(int count, int nameLength) => [
  for (var i = 0; i < count; i++)
    GitBranch(
      name: 'refs/heads/${'b' * nameLength}${i.toString().padLeft(3, '0')}',
      displayName: '${'b' * nameLength}${i.toString().padLeft(3, '0')}',
      oid: 'oid-$i',
      kind: 'local',
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('GitGraphBranchLimit 档位', () {
    test('默认 5；storage 值稳定解析（旧/坏值回退 5）', () {
      expect(GitGraphBranchLimit.fallback, GitGraphBranchLimit.five);
      expect(GitGraphBranchLimit.five.max, 5);
      expect(GitGraphBranchLimit.ten.max, 10);
      expect(GitGraphBranchLimit.unlimited.max, isNull);
      expect(GitGraphBranchLimit.unlimited.isUnlimited, isTrue);
      expect(GitGraphBranchLimit.fromStorage('10'), GitGraphBranchLimit.ten);
      expect(
        GitGraphBranchLimit.fromStorage('unlimited'),
        GitGraphBranchLimit.unlimited,
      );
      expect(GitGraphBranchLimit.fromStorage(null), GitGraphBranchLimit.five);
      expect(GitGraphBranchLimit.fromStorage('99'), GitGraphBranchLimit.five);
    });

    test('全局偏好持久化：默认 5，切 10/不限后重启保留', () async {
      final store = AppStore();
      await store.loadPrefs();
      expect(store.gitGraphBranchLimit, GitGraphBranchLimit.five);
      await store.setGitGraphBranchLimit(GitGraphBranchLimit.ten);
      final restored = AppStore();
      await restored.loadPrefs();
      expect(restored.gitGraphBranchLimit, GitGraphBranchLimit.ten);
      await restored.setGitGraphBranchLimit(GitGraphBranchLimit.unlimited);
      final restored2 = AppStore();
      await restored2.loadPrefs();
      expect(restored2.gitGraphBranchLimit, GitGraphBranchLimit.unlimited);
    });
  });

  group('controller 上限行为', () {
    test('默认 5：第 6 个分支被拒绝；升到 10 后可继续选', () async {
      final api = _FakeGitApi();
      final controller = GitBrowserController(api);
      addTearDown(controller.dispose);
      await controller.open('s');
      for (var i = 1; i < 5; i++) {
        expect(await controller.toggleGraphBranch(_branches(12)[i]), isTrue);
      }
      expect(controller.state.selectedBranches, hasLength(5));
      expect(await controller.toggleGraphBranch(_branches(12)[5]), isFalse);
      expect(controller.state.selectedBranches, hasLength(5));

      expect(controller.setBranchLimit(GitGraphBranchLimit.ten), 0);
      expect(await controller.toggleGraphBranch(_branches(12)[5]), isTrue);
      expect(controller.state.selectedBranches, hasLength(6));
      expect(api.graphTips.last, hasLength(6));
    });

    test('unlimited：不设硬上限（可超过 10/16，不自动全选）', () async {
      final api = _FakeGitApi(branchCount: 30);
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      expect(controller.state.selectedBranches, hasLength(1), reason: '打开只选默认分支');
      for (var i = 1; i < 20; i++) {
        expect(await controller.toggleGraphBranch(_branches(30)[i]), isTrue);
      }
      expect(controller.state.selectedBranches, hasLength(20));
    });

    test('降档自动保留前 N 个并重载 graph；升档保留选择', () async {
      final api = _FakeGitApi();
      final controller = GitBrowserController(api);
      addTearDown(controller.dispose);
      await controller.open('s');
      controller.setBranchLimit(GitGraphBranchLimit.ten);
      for (var i = 1; i < 8; i++) {
        await controller.toggleGraphBranch(_branches(12)[i]);
      }
      expect(controller.state.selectedBranches, hasLength(8));
      final keptNames = controller.state.selectedBranches
          .map((branch) => branch.name)
          .toList();

      final removed = controller.setBranchLimit(GitGraphBranchLimit.five);
      expect(removed, 3);
      expect(controller.state.selectedBranches, hasLength(5));
      expect(
        controller.state.selectedBranches.map((branch) => branch.name),
        keptNames.take(5),
        reason: '保留当前选择顺序前 N 个',
      );
      expect(api.graphTips.last, hasLength(5), reason: '裁剪后按新选择集重载 graph');

      // 升档不再裁剪。
      expect(controller.setBranchLimit(GitGraphBranchLimit.ten), 0);
      expect(controller.state.selectedBranches, hasLength(5));
    });

    test('unlimited 全选是 union：只加搜索结果中未选的，保留搜索外已选；清空到 0', () async {
      final api = _FakeGitApi();
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      final all = _branches(12);
      // 搜索外已选 b0（默认）；搜索结果（endWith '1'）是 b1/b11。
      final searchResults = all.where((b) => b.displayName.endsWith('1')).toList();
      final added = await controller.selectGraphBranches(searchResults);
      expect(added, 2);
      expect(controller.state.selectedBranches, hasLength(3));
      expect(
        controller.state.selectedBranches.map((b) => b.name),
        containsAll([
          all.first.name,
          ...searchResults.map((b) => b.name),
        ]),
      );
      expect(api.graphTips.last, hasLength(3), reason: 'graph 按并集选择集加载');

      // 再点全选同一搜索结果：幂等（没有新增，不发起重复请求）。
      final tipsBefore = api.graphTips.length;
      expect(await controller.selectGraphBranches(searchResults), 0);
      expect(api.graphTips.length, tipsBefore);

      controller.clearGraphBranches();
      expect(controller.state.selectedBranches, isEmpty);
      expect(controller.state.commits, isEmpty);
      expect(controller.state.graphNextCursor, isNull);
    });

    test('5/10 档不暴露全选/清空（controller 层也拒绝）', () async {
      final controller = GitBrowserController(_FakeGitApi());
      addTearDown(controller.dispose);
      await controller.open('s');
      await controller.selectGraphBranches(_branches(12));
      expect(controller.state.selectedBranches, hasLength(1));
      controller.clearGraphBranches();
      expect(controller.state.selectedBranches, hasLength(1));
    });
  });

  group('16 色 palette', () {
    test('调色板 16 色；10 个已选分支的颜色互不重复', () {
      const palette = 16;
      expect(maxNodeColorSegments, palette);
      final selected = _branches(10);
      for (final brightness in Brightness.values) {
        final colors = [
          for (var slot = 0; slot < selected.length; slot++)
            gitLaneColor(slot, selected, brightness),
        ];
        expect(colors.toSet(), hasLength(10), reason: '10 档不撞色（${brightness.name}）');
      }
    });

    test('超过 16 个分支循环复用槽位，不崩溃', () {
      final selected = _branches(20);
      for (var slot = 0; slot < 24; slot++) {
        expect(() => gitLaneColor(slot, selected, Brightness.light), returnsNormally);
      }
      final layout = layoutGraph(
        [for (var i = 0; i < 20; i++) GitCommitSummary(oid: 'oid-$i', parents: const [])],
        selected,
      );
      expect(layout.rows, hasLength(20));
    });
  });
  group('P2-2 改档不等待网络 / 操作代际', () {
    test('setBranchLimit 同步返回；旧请求迟到不回写，新请求按新选择集', () async {
      final api = _FakeGitApi()..queueGates = true;
      final controller = GitBrowserController(api);
      addTearDown(controller.dispose);
      await controller.open('s');

      // 第一个 graph 请求挂起（模拟慢网络）。
      unawaited(controller.openBranch(_branches(12)[0]));
      await Future<void>.delayed(Duration.zero);
      expect(api.pendingGates, hasLength(1));

      // 改档同步返回：不等待 graph 网络、选择/上限立即生效。
      final removed = controller.setBranchLimit(GitGraphBranchLimit.ten);
      expect(removed, 0);
      expect(controller.branchLimit, GitGraphBranchLimit.ten);
      expect(controller.state.loadingGraph, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(api.pendingGates, hasLength(2), reason: '改档后应发起新请求而非等待旧请求');

      // 旧请求迟到完成：generation 作废，不得回写 commits/选择。
      api.pendingGates[0].complete(
        const GitGraphPage(snapshotId: 'old', nextCursor: 'old', commits: []),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.snapshotId, isNot('old'));
      expect(controller.state.graphNextCursor, isNot('old'));

      // 新请求完成：正常落盘。
      api.pendingGates[1].complete(
        const GitGraphPage(snapshotId: 'new', nextCursor: null, commits: []),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.snapshotId, 'new');
      expect(controller.state.loadingGraph, isFalse);
    });
  });

  group('P2-3 不限档取消最后一项', () {
    test('unlimited 取消最后一项 → 0 选择、取消请求、无新 graph 请求', () async {
      final api = _FakeGitApi();
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      expect(controller.state.selectedBranches, hasLength(1));
      final requestsBefore = api.graphTips.length;

      expect(await controller.toggleGraphBranch(_branches(12)[0]), isTrue);
      expect(controller.state.selectedBranches, isEmpty);
      expect(controller.state.commits, isEmpty);
      expect(controller.state.loadingGraph, isFalse);
      expect(api.graphTips.length, requestsBefore, reason: '0 选择不应发起 graph 请求');
    });

    test('5/10 取消最后一项仍被拒绝（至少保留 1 个）', () async {
      final controller = GitBrowserController(_FakeGitApi());
      addTearDown(controller.dispose);
      await controller.open('s');
      expect(await controller.toggleGraphBranch(_branches(12)[0]), isFalse);
      expect(controller.state.selectedBranches, hasLength(1));
    });
  });

  group('P2-4 16 色槽位', () {
    test('恰好 16 槽、按顺序取值、17/20 循环；与已选分支名/顺序无关', () {
      for (final brightness in Brightness.values) {
        final colors = [
          for (var slot = 0; slot < 16; slot++)
            gitLaneColor(slot, const [], brightness),
        ];
        expect(colors.toSet(), hasLength(16), reason: '恰好 16 个不同槽（$brightness）');
        expect(gitLaneColor(16, const [], brightness), colors[0]);
        expect(gitLaneColor(17, const [], brightness), colors[1]);
        expect(gitLaneColor(20, const [], brightness), colors[4]);

        // 选择集合/顺序不影响 lane 槽位（老实现按名字 hash 会改变颜色）。
        final selected = _branches(20).reversed.toList();
        for (var slot = 0; slot < 20; slot++) {
          expect(
            gitLaneColor(slot, selected, brightness),
            colors[slot % 16],
            reason: 'slot $slot 循环复用（$brightness）',
          );
        }
      }
    });

    test('同 tip 多分支：每支一槽且槽位循环在 0..15；20 选的锚点无额外槽', () {
      final branches = _branches(20);
      final sharedTipCommit = GitCommitSummary(
        oid: branches[3].oid,
        parents: const [],
      );
      // 第 4 个与第 17 个已选分支指向同一 tip → 槽位 3 与 0（16 % 16），无 >15 槽。
      final selected = [
        ...branches.take(3),
        branches[3],
        ...branches.skip(4).take(12),
        branches[3],
      ];
      final slots = selectedTipColorSlots(sharedTipCommit, selected);
      expect(slots, [3, 0]);
      expect(slots.every((slot) => slot >= 0 && slot < 16), isTrue);

      final layout = layoutGraph([sharedTipCommit], selected);
      expect(layout.rows.single.tipColorSlots, [3, 0]);
      expect(
        layout.rows.single.tipColorSlots.every((slot) => slot < 16),
        isTrue,
      );
    });
  });
  group('task-28 GET/POST 传输', () {
    test('n≤getMax GET；getMax<n≤max POST（不限档 64 tips）', () async {
      final api = _TransportApi();
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      // 打开默认分支图：1 个已选 → GET。
      await controller.openBranch(_branches(160)[0]);
      expect(api.getCalls, greaterThan(0));
      expect(api.postCalls, 0, reason: '≤32 GET');

      for (var i = 1; i < 64; i++) {
        await controller.toggleGraphBranch(_branches(160)[i]);
      }
      expect(api.postCalls, greaterThan(0), reason: '64 tips → POST');
      expect(api.graphTips.last, hasLength(64));
    });

    test('URL 预算：编码 tips >8KB 时优先 POST', () async {
      final api = _TransportApi();
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      final longBranches = _namedBranches(32, 300);
      await controller.selectGraphBranches(longBranches);
      expect(api.postCalls, greaterThan(0), reason: 'URL 预算超限 → POST');
    });

    test('GET 431 → 自动回退 POST 一次', () async {
      final api = _TransportApi()..failGet431Once = true;
      final controller = GitBrowserController(api);
      addTearDown(controller.dispose);
      await controller.open('s');
      await controller.toggleGraphBranch(_branches(160)[1]);
      expect(api.postCalls, 1);
      expect(controller.state.snapshotId, 'post');
    });

    test('POST 504（不限档）→ 同一超时面板；400/413 → 错误码', () async {
      final api = _TransportApi(branchCount: 160);
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      await controller.selectGraphBranches(_branches(160).take(64).toList());
      expect(api.postCalls, greaterThan(0));

      api.postError = ApiException(
        'graph deadline',
        code: 'graph-timeout',
        status: 504,
      );
      await controller.toggleGraphBranch(_branches(160)[70]);
      expect(controller.state.graphTimedOut, isTrue);
      expect(controller.state.error, isNull);

      api.postError = ApiException(
        'too many',
        code: 'graph-too-many-tips',
        status: 400,
      );
      await controller.toggleGraphBranch(_branches(160)[71]);
      expect(controller.state.error, 'graph-too-many-tips');
    });

    test('旧宿主（无 graphTips）：10/不限 clamp 回 5、上限 5', () async {
      final api = _TransportApi(
        capsOverride: const GitReadCapabilities(available: true),
      );
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      expect(controller.state.branchLimit, GitGraphBranchLimit.five);
      controller.setBranchLimit(GitGraphBranchLimit.ten);
      for (var i = 1; i < 6; i++) {
        await controller.toggleGraphBranch(_branches(160)[i]);
      }
      expect(controller.state.selectedBranches, hasLength(5));
      expect(controller.state.capabilities?.supportsGraphPost, isFalse);
    });

    test('>max 事前阻止：服务端上限 128，129 不加；union 截断到 128', () async {
      final api = _TransportApi();
      final controller = GitBrowserController(
        api,
        branchLimit: GitGraphBranchLimit.unlimited,
      );
      addTearDown(controller.dispose);
      await controller.open('s');
      await controller.selectGraphBranches(_branches(160).take(120).toList());
      expect(controller.state.selectedBranches, hasLength(120));
      final added = await controller.selectGraphBranches(
        _branches(160).skip(120).take(10).toList(),
      );
      expect(added, 8);
      expect(controller.state.selectedBranches, hasLength(128));
      expect(
        await controller.toggleGraphBranch(_branches(160)[130]),
        isFalse,
        reason: '超过服务端 max 时不加',
      );
    });
  });
}
