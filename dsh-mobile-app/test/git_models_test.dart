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

  test('structured refsDetail/tagsDetail parse for graph rows and commit detail', () {
    final summary = GitCommitSummary.fromJson({
      'oid': 'abc',
      'refs': ['refs/heads/main'],
      'tags': ['v1'],
      'refsDetail': [
        {
          'kind': 'head',
          'name': 'refs/heads/main',
          'shortName': 'main',
          'oid': 'abc',
          'current': true,
        },
        {
          'kind': 'localBranch',
          'name': 'refs/heads/feature',
          'shortName': 'feature',
          'oid': 'abc',
        },
        {
          'kind': 'remoteBranch',
          'name': 'refs/remotes/origin/main',
          'shortName': 'origin/main',
          'oid': 'abc',
        },
        {
          'kind': 'other',
          'name': 'refs/stash',
          'shortName': 'stash',
          'oid': 'abc',
        },
      ],
      'tagsDetail': [
        {'name': 'refs/tags/v1', 'shortName': 'v1', 'oid': 'abc', 'annotated': true},
      ],
    });
    final details = GitCommitDetails.fromJson({
      'oid': 'abc',
      'refsDetail': [
        {
          'kind': 'head',
          'name': 'refs/heads/main',
          'shortName': 'main',
          'oid': 'abc',
          'current': true,
        },
      ],
      'tagsDetail': [
        {
          'name': 'refs/tags/v2',
          'shortName': 'v2',
          'oid': 'abc',
          'annotated': true,
          'tagger': 'Release Bot',
          'date': 1700000000,
          'subject': 'release 2.0',
          'hint': 'non-commit-target',
        },
      ],
    });

    expect(summary.decoration.refs, hasLength(4));
    expect(summary.decoration.refs.first.kind, GitRefKind.head);
    expect(summary.decoration.refs.first.isHead, isTrue);
    expect(summary.decoration.refs.first.current, isTrue);
    expect(summary.decoration.refs[2].isRemoteBranch, isTrue);
    expect(summary.decoration.refs.last.isStash, isTrue);
    expect(summary.decoration.tags.single.annotated, isTrue);
    // legacy 字段仍保留（deprecated 契约兼容）。
    expect(summary.refs, ['refs/heads/main']);
    expect(summary.tags, ['v1']);

    expect(details.decoration.refs.single.shortName, 'main');
    final tag = details.decoration.tags.single;
    expect(tag.shortName, 'v2');
    expect(tag.tagger, 'Release Bot');
    expect(tag.timestamp, 1700000000);
    expect(tag.subject, 'release 2.0');
    expect(tag.hint, 'non-commit-target');
    expect(tag.hasMetadata, isTrue);
  });

  test('legacy ref/tag decoration strings fall back when structured fields are absent', () {
    final summary = GitCommitSummary.fromJson({
      'oid': 'abc',
      'refs': [
        'HEAD -> refs/heads/main',
        'refs/heads/feature',
        'refs/remotes/origin/main',
        'tag: refs/tags/v1',
      ],
      'tags': ['v2'],
    });
    final details = GitCommitDetails(
      oid: 'abc',
      refs: ['main'],
      tags: ['v1.0'],
    );

    expect(
      summary.decoration.refs.map((ref) => ref.kind).toList(),
      [
        GitRefKind.head,
        GitRefKind.localBranch,
        GitRefKind.localBranch,
        GitRefKind.remoteBranch,
      ],
    );
    // 旧宿主 `HEAD -> refs/heads/main` 同时投影 head 与 current localBranch。
    expect(summary.decoration.refs[0].isHead, isTrue);
    expect(summary.decoration.refs[0].shortName, 'main');
    expect(summary.decoration.refs[1].isLocalBranch, isTrue);
    expect(summary.decoration.refs[1].current, isTrue);
    expect(summary.decoration.refs[1].shortName, 'main');
    expect(
      summary.decoration.tags.map((tag) => tag.shortName).toList(),
      ['v1', 'v2'],
    );
    expect(summary.decoration.tags.every((tag) => !tag.annotated), isTrue);
    // 直接构造（旧宿主/测试桩）的模型也能从 legacy 字段派生展示数据。
    expect(details.resolvedDecoration.refs.single.shortName, 'main');
    expect(details.resolvedDecoration.tags.single.shortName, 'v1.0');
  });

  test('capability flags gate file history and structured refs independently', () {
    final caps = GitReadCapabilities.fromJson({
      'available': true,
      'features': {'refsDetail': true, 'fileHistory': false},
    });
    final legacy = GitReadCapabilities.fromJson({
      'available': true,
      'features': {'graph': true},
    });

    expect(caps.refsDetail, isTrue);
    expect(caps.fileHistory, isFalse);
    expect(legacy.refsDetail, isFalse);
    expect(legacy.fileHistory, isFalse);
  });

  test('file list and file history DTOs parse the host contract', () {
    final files = GitFileList.fromJson({
      'ok': true,
      'repositoryId': 'repo',
      'files': ['lib/a.dart', 'README.md'],
      'truncated': true,
    });
    final objectFiles = GitFileList.fromJson({
      'files': [
        {'path': 'lib/object.dart'},
      ],
    });
    final history = GitFileHistoryPage.fromJson({
      'ok': true,
      'repositoryId': 'repo',
      'path': 'lib/a.dart',
      'entries': [
        {
          'oid': 'abcdef1234567890',
          'shortOid': 'abcdef1',
          'author': 'Ada',
          'timestamp': 1700000000,
          'subject': 'update a',
          'status': 'M',
        },
        {'oid': '12345678', 'author': 'Bob', 'status': 'A'},
      ],
      'nextCursor': 'cursor-2',
      'truncated': true,
    });
    final empty = GitFileHistoryPage.fromJson({
      'entries': [],
      'nextCursor': null,
      'truncated': false,
      'reason': 'not-tracked',
    });

    expect(files.files, ['lib/a.dart', 'README.md']);
    expect(files.truncated, isTrue);
    expect(objectFiles.files, ['lib/object.dart']);
    expect(history.entries.first.shortOid, 'abcdef1');
    expect(history.entries.first.status, 'M');
    expect(history.entries.last.shortOid, '12345678');
    expect(history.nextCursor, 'cursor-2');
    expect(history.truncated, isTrue);
    expect(empty.entries, isEmpty);
    expect(empty.reason, 'not-tracked');
    expect(empty.nextCursor, isNull);
  });
}
