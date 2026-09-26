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

  test('openBranch replaces selection and graph selection stays between one and three', () async {
    final fourth = GitBranch(
      name: 'refs/heads/fourth',
      displayName: 'fourth',
      oid: 'fourth-oid',
      kind: 'local',
    );
    final api = FakeGitReadApi()
      ..onBranches = (_, _) async => [
        localMain,
        localFeature,
        remoteMain,
        fourth,
      ];
    final controller = GitBrowserController(api);
    await controller.open('session-a');

    await controller.openBranch(localFeature);
    expect(controller.state.selectedBranches, [localFeature]);
    expect(await controller.toggleGraphBranch(remoteMain), isTrue);
    expect(await controller.toggleGraphBranch(localMain), isTrue);
    expect(await controller.toggleGraphBranch(fourth), isFalse);
    expect(controller.state.selectedBranches, [
      localFeature,
      remoteMain,
      localMain,
    ]);
    expect(await controller.toggleGraphBranch(localFeature), isTrue);
    expect(await controller.toggleGraphBranch(remoteMain), isTrue);
    expect(await controller.toggleGraphBranch(localMain), isFalse);
    expect(controller.state.selectedBranches, [localMain]);
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
    pending.complete(const GitRepository(repositoryId: 'repo', name: 'project'));
    await opening;
    expect(controller.state.repository, isNull);
  });

  test('stale change during graph request keeps loaded content until explicit refresh', () async {
    final pending = Completer<GitGraphPage>();
    final api = FakeGitReadApi()
      ..onGraph = (_, _, tips, snapshot, cursor, limit) =>
          cursor == null
              ? Future.value(GitGraphPage(
                  snapshotId: 'snap', nextCursor: 'next', tips: tips,
                  commits: const [GitCommitSummary(oid: 'first')]))
              : pending.future;
    final controller = GitBrowserController(api);
    await controller.open('session-a');
    await controller.openBranch(localMain);
    final loading = controller.loadNextGraphPage();
    controller.markStale();
    pending.complete(const GitGraphPage(snapshotId: 'snap', commits: [GitCommitSummary(oid: 'second')]));
    await loading;
    expect(controller.state.stale, isTrue);
    expect(controller.state.commits.map((c) => c.oid), ['first']);
    expect(controller.state.snapshotId, 'snap');
    await controller.loadNextGraphPage();
    expect(api.graphCalls, 2);
  });

  test('refresh failure keeps stale graph and successful refresh replaces snapshot', () async {
    final api = FakeGitReadApi()
      ..onGraph = (_, _, tips, snapshot, cursor, limit) async =>
          GitGraphPage(snapshotId: 'old', tips: tips,
              commits: const [GitCommitSummary(oid: 'old')] );
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
    api.onGraph = (_, _, tips, snapshot, cursor, limit) async =>
        GitGraphPage(snapshotId: 'new', tips: tips,
            commits: const [GitCommitSummary(oid: 'new')]);
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
