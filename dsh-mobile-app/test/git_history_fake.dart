// 文件提交历史测试共用的假 GitReadApi（c3 修复轮抽出，widget/controller 测试共用）。
import 'dart:async';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/git_models.dart';

const _main = GitBranch(
  name: 'refs/heads/main',
  displayName: 'main',
  oid: 'main-oid',
  kind: 'local',
  current: true,
);

/// 图/预览/历史都可配置的假 Git API。
class HistoryGitApi implements GitReadApi {
  bool fileHistoryCapability = true;
  bool repositoryEmpty = false;
  bool failHistory = false;
  bool truncatedHistory = false;
  int pageOneCount = 2;
  bool failFiles = false;
  bool failCapabilities = false;
  bool failRepository = false;

  /// 使用带 10 行长上下文段的 fixture diff（用于折叠保活测试）。
  bool longDiff = false;
  final Set<String> binaryPaths = {};
  final Set<String> noticePaths = {};

  /// 非空时用这些状态字母生成第一页历史行（用于 C/T/unknown 徽标覆盖）。
  List<String>? statusesOverride;

  /// 挂起第二页历史请求（用于 loadingMore 竞态/翻页测试）。
  Completer<GitFileHistoryPage>? pageTwoGate;

  final List<String?> fileQueries = [];
  final List<String?> historyPaths = [];
  final List<String?> historyCursors = [];
  final List<({String kind, String path, String? oid})> previews = [];

  @override
  Future<GitReadCapabilities> capabilities(String sessionId) async {
    if (failCapabilities) throw ApiException('capabilities unavailable');
    return GitReadCapabilities(
      available: true,
      features: {'refsDetail': true, 'fileHistory': fileHistoryCapability},
    );
  }

  @override
  Future<GitRepository> repository(String sessionId) async {
    if (failRepository) throw ApiException('repository unavailable');
    return GitRepository(
      repositoryId: 'repo-1',
      name: 'example',
      headOid: 'main-oid',
      currentBranch: 'refs/heads/main',
      empty: repositoryEmpty,
    );
  }

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
  }) async {
    previews.add((kind: kind, path: path, oid: oid));
    return GitFilePreview(
      repositoryId: repositoryId,
      kind: kind,
      path: path,
      binary: binaryPaths.contains(path),
      notice: noticePaths.contains(path) ? 'preview unavailable' : null,
      diff: longDiff
          ? 'diff --git a/$path b/$path\n'
                '@@ -1,10 +1,10 @@\n'
                ' keep 1\n keep 2\n keep 3\n'
                '-old line\n'
                '+new line\n'
                '--- source -- marker\n'
                '+++ source ++ marker\n'
                ' keep 4\n keep 5\n keep 6\n keep 7\n keep 8\n keep 9\n keep 10\n'
          : 'diff --git a/$path b/$path\n@@ -1 +1 @@\n-old line\n+new line\n',
    );
  }

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
      return GitFileHistoryPage(
        repositoryId: repositoryId,
        path: path,
        reason: 'not-tracked',
      );
    }
    if (path.contains('bad')) {
      return GitFileHistoryPage(
        repositoryId: repositoryId,
        path: path,
        reason: 'path-invalid',
      );
    }
    if (repositoryEmpty) {
      return GitFileHistoryPage(
        repositoryId: repositoryId,
        path: path,
        reason: 'no-history',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final statuses = statusesOverride;
    if (cursor != null) {
      final gate = pageTwoGate;
      if (gate != null) return gate.future;
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
    if (statuses != null) {
      return GitFileHistoryPage(
        repositoryId: repositoryId,
        path: path,
        entries: [
          for (var i = 0; i < statuses.length; i++)
            GitFileHistoryEntry(
              oid: 'status-oid-$i',
              shortOid: 'status-$i',
              author: 'Ada',
              timestamp: now - 3600,
              subject: 'Status $i',
              status: statuses[i],
            ),
        ],
        truncated: truncatedHistory,
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
