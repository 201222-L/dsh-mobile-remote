import 'dart:async';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_browser_controller.dart';
import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter_test/flutter_test.dart';

const localMain = GitBranch(
  name: 'refs/heads/main',
  displayName: 'main',
  oid: 'main-oid',
  kind: 'local',
  current: true,
);
const localFeature = GitBranch(
  name: 'refs/heads/feature',
  displayName: 'feature',
  oid: 'feature-oid',
  kind: 'local',
);
const remoteMain = GitBranch(
  name: 'refs/remotes/origin/main',
  displayName: 'origin/main',
  oid: 'remote-oid',
  kind: 'remote',
);

class FakeGitReadApi implements GitReadApi {
  Future<GitReadCapabilities> Function(String sessionId)? onCapabilities;
  Future<GitRepository> Function(String sessionId)? onRepository;
  Future<List<GitBranch>> Function(String sessionId, String repositoryId)?
  onBranches;
  Future<GitGraphPage> Function(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips,
    String? snapshotId,
    String? cursor,
    int limit,
  )?
  onGraph;
  Future<GitCommitDetails> Function(
    String sessionId,
    String repositoryId,
    String oid,
    String? filesCursor,
    int filesLimit,
  )?
  onCommit;
  Future<GitWorktreeSnapshot> Function(String sessionId, String repositoryId)?
  onWorktree;
  Future<GitFilePreview> Function(
    String sessionId,
    String repositoryId,
    String kind,
    String path,
    String? snapshotId,
    String? oid,
  )?
  onPreview;

  int graphCalls = 0;
  int commitCalls = 0;

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) =>
      onCapabilities?.call(sessionId) ??
      Future.value(const GitReadCapabilities(available: true));

  @override
  Future<GitRepository> repository(String sessionId) =>
      onRepository?.call(sessionId) ??
      Future.value(
        const GitRepository(
          repositoryId: 'repo',
          name: 'project',
          headOid: 'main-oid',
          currentBranch: 'refs/heads/main',
        ),
      );

  @override
  Future<List<GitBranch>> branches(String sessionId, String repositoryId) =>
      onBranches?.call(sessionId, repositoryId) ??
      Future.value(const [localFeature, localMain, remoteMain]);

  @override
  Future<GitGraphPage> graph(
    String sessionId,
    String repositoryId,
    List<GitGraphTip> tips, {
    String? snapshotId,
    String? cursor,
    int limit = 100,
  }) {
    graphCalls++;
    return onGraph?.call(
          sessionId,
          repositoryId,
          tips,
          snapshotId,
          cursor,
          limit,
        ) ??
        Future.value(
          GitGraphPage(
            snapshotId: snapshotId ?? 'snapshot',
            nextCursor: null,
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
  }) {
    commitCalls++;
    return onCommit?.call(
          sessionId,
          repositoryId,
          oid,
          filesCursor,
          filesLimit,
        ) ??
        Future.value(GitCommitDetails(oid: oid));
  }

  @override
  Future<GitWorktreeSnapshot> worktree(String sessionId, String repositoryId) =>
      onWorktree?.call(sessionId, repositoryId) ??
      Future.value(
        const GitWorktreeSnapshot(
          repositoryId: 'repo',
          snapshotId: 'worktree-1',
        ),
      );

  @override
  Future<GitFilePreview> preview(
    String sessionId,
    String repositoryId, {
    required String kind,
    required String path,
    String? snapshotId,
    String? oid,
  }) =>
      onPreview?.call(sessionId, repositoryId, kind, path, snapshotId, oid) ??
      Future.value(
        GitFilePreview(
          repositoryId: repositoryId,
          kind: kind,
          path: path,
          diff: '-old\n+new\n',
        ),
      );
}

void main() {
  test(
    'open loads branches, selects current branch, and filters locally',
    () async {
      final controller = GitBrowserController(FakeGitReadApi());

      await controller.open('session-a');

      expect(controller.state.branches.map((branch) => branch.name), [
        'refs/heads/main',
        'refs/heads/feature',
        'refs/remotes/origin/main',
      ]);
      expect(controller.state.selectedBranches, [localMain]);
      controller.setBranchQuery('ORIGIN');
      expect(controller.state.filteredBranches, [remoteMain]);
    },
  );

  test(
    'an older freshness poll cannot stale a newer explicit refresh',
    () async {
      final api = FakeGitReadApi();
      final latePoll = Completer<GitWorktreeSnapshot>();
      var calls = 0;
      api.onWorktree = (_, _) {
        calls++;
        if (calls == 2) return latePoll.future;
        return Future.value(
          GitWorktreeSnapshot(
            repositoryId: 'repo',
            snapshotId: 'snapshot-$calls',
          ),
        );
      };
      final controller = GitBrowserController(api);
      await controller.open('session-a');
      await controller.loadWorktree();
      final polling = controller.checkWorktreeFreshness();
      await controller.loadWorktree(refresh: true);
      latePoll.complete(
        const GitWorktreeSnapshot(
          repositoryId: 'repo',
          snapshotId: 'older-poll-result',
        ),
      );
      await polling;

      expect(controller.state.worktree!.snapshotId, 'snapshot-3');
      expect(controller.state.worktreeStale, isFalse);
    },
  );

  test('opening a branch exposes the pending graph load until its snapshot arrives', () async {
    final api = FakeGitReadApi();
    final page = Completer<GitGraphPage>();
    api.onGraph = (_, _, _, _, _, _) => page.future;
    final controller = GitBrowserController(api);
    await controller.open('session-a');

    final pending = controller.openBranch(localMain);
    expect(controller.state.loadingGraph, isTrue);
    page.complete(
      GitGraphPage(
        snapshotId: 'graph-snapshot',
        tips: const [GitGraphTip(name: 'refs/heads/main', tipOid: 'main-oid')],
      ),
    );
    await pending;
    expect(controller.state.loadingGraph, isFalse);
    expect(controller.state.snapshotId, 'graph-snapshot');
  });

  test('worktree refresh detects changes but retains the visible snapshot and preview', () async {
    final api = FakeGitReadApi();
    var worktreeCalls = 0;
    api.onWorktree = (_, _) async {
      worktreeCalls++;
      return GitWorktreeSnapshot(
        repositoryId: 'repo',
        snapshotId: 'snapshot-$worktreeCalls',
        staged: const [GitWorktreeFile(path: 'a.txt', status: 'modified')],
      );
    };
    final controller = GitBrowserController(api);
    await controller.open('session-a');
    await controller.loadWorktree();
    await controller.openPreview(kind: 'staged', path: 'a.txt');
    final previousSnapshot = controller.state.worktree;
    final previousPreview = controller.state.preview;

    await controller.checkWorktreeFreshness();

    expect(controller.state.worktreeStale, isTrue);
    expect(controller.state.worktree, same(previousSnapshot));
    expect(controller.state.preview, same(previousPreview));
    await controller.checkWorktreeFreshness();
    expect(worktreeCalls, 2, reason: 'stale state waits for explicit refresh');
    await controller.loadWorktree(refresh: true);
    expect(controller.state.worktreeStale, isFalse);
    expect(controller.state.worktree!.snapshotId, 'snapshot-3');
  });

  test('openBranch replaces selection and graph selection stays between one and five', () async {
    final fourth = GitBranch(
      name: 'refs/heads/fourth',
      displayName: 'fourth',
      oid: 'fourth-oid',
      kind: 'local',
    );
    final fifth = GitBranch(
      name: 'refs/remotes/origin/fifth',
      displayName: 'origin/fifth',
      oid: 'fifth-oid',
      kind: 'remote',
    );
    final sixth = GitBranch(
      name: 'refs/heads/sixth',
      displayName: 'sixth',
      oid: 'sixth-oid',
      kind: 'local',
    );
    final api = FakeGitReadApi()
      ..onBranches = (_, _) async => [
        localMain,
        localFeature,
        remoteMain,
        fourth,
        fifth,
        sixth,
      ];
    final controller = GitBrowserController(api);
    await controller.open('session-a');

    await controller.openBranch(localFeature);
    expect(controller.state.selectedBranches, [localFeature]);
    expect(await controller.toggleGraphBranch(remoteMain), isTrue);
    expect(await controller.toggleGraphBranch(localMain), isTrue);
    expect(await controller.toggleGraphBranch(fourth), isTrue);
    expect(await controller.toggleGraphBranch(fifth), isTrue);
    expect(await controller.toggleGraphBranch(sixth), isFalse);
    expect(controller.state.selectedBranches, [
      localFeature,
      remoteMain,
      localMain,
      fourth,
      fifth,
    ]);
    expect(await controller.toggleGraphBranch(localFeature), isTrue);
    expect(await controller.toggleGraphBranch(remoteMain), isTrue);
    expect(await controller.toggleGraphBranch(localMain), isTrue);
    expect(await controller.toggleGraphBranch(fourth), isTrue);
    expect(await controller.toggleGraphBranch(fifth), isFalse);
    expect(controller.state.selectedBranches, [fifth]);
  });

  test(
    'markStale retains loaded branches, graph, snapshot and commit',
    () async {
      final api = FakeGitReadApi();
      api.onGraph = (_, _, tips, snapshot, cursor, limit) async => GitGraphPage(
        snapshotId: 'snapshot-1',
        nextCursor: 'next',
        tips: tips,
        commits: const [GitCommitSummary(oid: 'abc')],
      );
      api.onCommit = (_, _, oid, cursor, limit) async => GitCommitDetails(
        oid: oid,
        files: const [GitCommitFile(path: 'a.dart')],
        filesTotal: 1,
      );
      final controller = GitBrowserController(api);
      await controller.open('session-a');
      await controller.openBranch(localMain);
      await controller.openCommit('abc');
      final before = controller.state;

      controller.markStale();

      expect(controller.state.stale, isTrue);
      expect(controller.state.branches, same(before.branches));
      expect(controller.state.commits, same(before.commits));
      expect(controller.state.snapshotId, 'snapshot-1');
      expect(controller.state.commit, same(before.commit));
    },
  );

  test(
    'graph pagination dedupes concurrent loads and duplicate commits',
    () async {
      final next = Completer<GitGraphPage>();
      final api = FakeGitReadApi()
        ..onGraph = (_, _, tips, snapshot, cursor, limit) {
          if (cursor == null) {
            return Future.value(
              GitGraphPage(
                snapshotId: 'snapshot-1',
                nextCursor: 'cursor-1',
                tips: tips,
                commits: const [
                  GitCommitSummary(oid: 'a'),
                  GitCommitSummary(oid: 'b'),
                ],
              ),
            );
          }
          expect(snapshot, 'snapshot-1');
          expect(cursor, 'cursor-1');
          return next.future;
        };
      final controller = GitBrowserController(api);
      await controller.open('session-a');
      await controller.openBranch(localMain);

      final first = controller.loadNextGraphPage();
      final duplicate = controller.loadNextGraphPage();
      expect(api.graphCalls, 2);
      next.complete(
        const GitGraphPage(
          snapshotId: 'snapshot-1',
          commits: [
            GitCommitSummary(oid: 'b'),
            GitCommitSummary(oid: 'c'),
          ],
        ),
      );
      await Future.wait([first, duplicate]);

      expect(controller.state.commits.map((commit) => commit.oid), [
        'a',
        'b',
        'c',
      ]);
      expect(controller.state.graphNextCursor, isNull);
    },
  );

  test(
    'commit file pagination dedupes in-flight requests and repeated files',
    () async {
      final next = Completer<GitCommitDetails>();
      final api = FakeGitReadApi()
        ..onCommit = (_, _, oid, cursor, limit) {
          if (cursor == null) {
            return Future.value(
              const GitCommitDetails(
                oid: 'abc',
                files: [GitCommitFile(path: 'a.dart')],
                filesTotal: 2,
                filesNextCursor: 'files-1',
              ),
            );
          }
          return next.future;
        };
      final controller = GitBrowserController(api);
      await controller.open('session-a');
      await controller.openCommit('abc');

      final first = controller.loadNextFilesPage();
      final duplicate = controller.loadNextFilesPage();
      expect(api.commitCalls, 2);
      next.complete(
        const GitCommitDetails(
          oid: 'abc',
          files: [
            GitCommitFile(path: 'a.dart'),
            GitCommitFile(path: 'b.dart'),
          ],
          filesTotal: 2,
        ),
      );
      await Future.wait([first, duplicate]);

      expect(controller.state.commit!.files.map((file) => file.path), [
        'a.dart',
        'b.dart',
      ]);
    },
  );

  test('closing browser ignores pending repository response', () async {
    final pending = Completer<GitRepository>();
    final api = FakeGitReadApi()..onRepository = (_) => pending.future;
    final controller = GitBrowserController(api);
    final opening = controller.open('session-a');
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    pending.complete(
      const GitRepository(repositoryId: 'repo', name: 'project'),
    );
    await opening;
    expect(controller.state.repository, isNull);
  });

  test('stale change during graph request keeps loaded content until explicit refresh', () async {
    final pending = Completer<GitGraphPage>();
    final api = FakeGitReadApi()
      ..onGraph = (_, _, tips, snapshot, cursor, limit) => cursor == null
          ? Future.value(
              GitGraphPage(
                snapshotId: 'snap',
                nextCursor: 'next',
                tips: tips,
                commits: const [GitCommitSummary(oid: 'first')],
              ),
            )
          : pending.future;
    final controller = GitBrowserController(api);
    await controller.open('session-a');
    await controller.openBranch(localMain);
    final loading = controller.loadNextGraphPage();
    controller.markStale();
    pending.complete(
      const GitGraphPage(
        snapshotId: 'snap',
        commits: [GitCommitSummary(oid: 'second')],
      ),
    );
    await loading;
    expect(controller.state.stale, isTrue);
    expect(controller.state.commits.map((c) => c.oid), ['first']);
    expect(controller.state.snapshotId, 'snap');
    await controller.loadNextGraphPage();
    expect(api.graphCalls, 2);
  });

  test('refresh failure keeps stale graph and successful refresh replaces snapshot', () async {
    final api = FakeGitReadApi()
      ..onGraph = (_, _, tips, snapshot, cursor, limit) async => GitGraphPage(
        snapshotId: 'old',
        tips: tips,
        commits: const [GitCommitSummary(oid: 'old')],
      );
    final controller = GitBrowserController(api);
    await controller.open('session-a');
    await controller.openBranch(localMain);
    controller.markStale();
    api.onGraph = (_, _, tips, snapshot, cursor, limit) =>
        Future.error(ApiException('stale', code: 'graph-stale'));
    await controller.refresh();
    expect(controller.state.stale, isTrue);
    expect(controller.state.commits.single.oid, 'old');
    expect(controller.state.snapshotId, 'old');
    api.onGraph = (_, _, tips, snapshot, cursor, limit) async => GitGraphPage(
      snapshotId: 'new',
      tips: tips,
      commits: const [GitCommitSummary(oid: 'new')],
    );
    await controller.refresh();
    expect(controller.state.stale, isFalse);
    expect(controller.state.snapshotId, 'new');
    expect(controller.state.commits.single.oid, 'new');
  });

  test(
    'late responses from an older session cannot replace the active session',
    () async {
      final aCapabilities = Completer<GitReadCapabilities>();
      final api = FakeGitReadApi();
      api.onCapabilities = (sessionId) => sessionId == 'A'
          ? aCapabilities.future
          : Future.value(const GitReadCapabilities(available: true));
      api.onRepository = (sessionId) async =>
          GitRepository(repositoryId: 'repo-$sessionId', name: sessionId);
      api.onBranches = (sessionId, _) async =>
          sessionId == 'B' ? const [remoteMain] : const [localMain];
      final controller = GitBrowserController(api);

      final first = controller.open('A');
      await controller.open('B');
      aCapabilities.complete(const GitReadCapabilities(available: true));
      await first;

      expect(controller.state.sessionId, 'B');
      expect(controller.state.repository!.repositoryId, 'repo-B');
      expect(controller.state.branches, [remoteMain]);
    },
  );
}
