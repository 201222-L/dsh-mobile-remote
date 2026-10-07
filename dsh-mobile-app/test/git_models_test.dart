import 'package:dsh_mobile_app/git_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'read-only Git DTOs preserve repository, branch, graph and commit data',
    () {
      final repository = GitRepository.fromJson({
        'repositoryId': 'repo-1',
        'name': 'project',
        'headOid': 'abc',
        'currentBranch': 'refs/heads/main',
        'detached': false,
        'empty': false,
      });
      final branch = GitBranch.fromJson({
        'name': 'refs/heads/main',
        'displayName': 'main',
        'oid': 'abc',
        'kind': 'local',
        'current': true,
        'tracking': 'origin/main',
        'ahead': 2,
        'behind': 1,
      });
      final page = GitGraphPage.fromJson({
        'snapshotId': 'snapshot-1',
        'nextCursor': 'cursor-2',
        'tips': [
          {'name': 'refs/heads/main', 'tipOid': 'abc'},
        ],
        'commits': [
          {
            'oid': 'abc',
            'parents': ['def'],
            'author': 'Alice',
            'timestamp': 1700000000,
            'subject': 'subject',
            'refs': ['refs/heads/main'],
            'tags': ['v1'],
          },
        ],
      });
      final details = GitCommitDetails.fromJson({
        'oid': 'abc',
        'parents': ['def'],
        'author': 'Alice',
        'timestamp': 1700000000,
        'message': 'subject\n\nbody',
        'refs': ['refs/heads/main'],
        'tags': ['v1'],
        'stats': {'additions': 3, 'deletions': 1, 'files': 1},
        'filesTotal': 1,
        'filesNextCursor': 'files-2',
        'files': [
          {
            'path': 'lib/a.dart',
            'oldPath': 'lib/old.dart',
            'status': 'renamed',
            'additions': 3,
            'deletions': 1,
            'binary': false,
          },
        ],
      });

      expect(repository.repositoryId, 'repo-1');
      expect(repository.currentBranch, 'refs/heads/main');
      expect(branch.isLocal, isTrue);
      expect(branch.tracking, 'origin/main');
      expect(branch.ahead, 2);
      expect(page.snapshotId, 'snapshot-1');
      expect(page.commits.single.parents, ['def']);
      expect(page.commits.single.tags, ['v1']);
      expect(details.message, contains('body'));
      expect(details.stats.additions, 3);
      expect(details.files.single.oldPath, 'lib/old.dart');
      expect(details.filesNextCursor, 'files-2');
    },
  );

  test('worktree and per-file preview DTOs preserve read-only facts', () {
    final workspace = GitWorktreeSnapshot.fromJson({
      'repositoryId': 'repo-1',
      'snapshotId': 'worktree-1',
      'staged': [
        {'path': 'file.txt', 'oldPath': 'old.txt', 'status': 'renamed'},
      ],
      'unstaged': [
        {'path': 'file.txt', 'status': 'modified'},
      ],
      'untracked': [
        {'path': 'new.txt', 'status': 'untracked'},
      ],
      'truncated': true,
    });
    final preview = GitFilePreview.fromJson({
      'repositoryId': 'repo-1',
      'kind': 'untracked',
      'path': 'new.txt',
      'diff': 'hello\n',
      'truncated': true,
      'binary': false,
      'additions': null,
      'deletions': null,
      'notice': 'content limit reached',
    });

    expect(workspace.snapshotId, 'worktree-1');
    expect(workspace.staged.single.oldPath, 'old.txt');
    expect(workspace.staged.single.path, workspace.unstaged.single.path);
    expect(workspace.untracked.single.status, 'untracked');
    expect(workspace.truncated, isTrue);
    expect(preview.diff, 'hello\n');
    expect(preview.truncated, isTrue);
    expect(preview.notice, 'content limit reached');
  });

  test(
    'capabilities retain stable unavailable reason without write fields',
    () {
      final value = GitReadCapabilities.fromJson({
        'available': false,
        'reason': 'git-provider-unavailable',
        'features': {'branches': true, 'graph': false},
      });

      expect(value.available, isFalse);
      expect(value.reason, 'git-provider-unavailable');
      expect(value.features, {'branches': true, 'graph': false});
    },
  );
}
