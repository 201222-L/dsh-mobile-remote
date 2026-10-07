import 'dart:collection';

const maxSelectedGraphBranches = 5;

List<String> _strings(Object? value) => (value as List? ?? const [])
    .map((item) => item.toString())
    .toList(growable: false);

Map<String, bool> _boolMap(Object? value) => Map.unmodifiable(
  (value as Map? ?? const {}).map(
    (key, item) => MapEntry(key.toString(), item == true),
  ),
);

class GitReadCapabilities {
  final bool available;
  final String? reason;
  final Map<String, bool> features;

  const GitReadCapabilities({
    this.available = false,
    this.reason,
    this.features = const {},
  });

  factory GitReadCapabilities.fromJson(Map<String, dynamic> json) =>
      GitReadCapabilities(
        available: json['available'] == true,
        reason: json['reason']?.toString(),
        features: _boolMap(json['features']),
      );
}

class GitRepository {
  final String repositoryId;
  final String name;
  final String? headOid;
  final String? currentBranch;
  final bool detached;
  final bool empty;

  const GitRepository({
    required this.repositoryId,
    required this.name,
    this.headOid,
    this.currentBranch,
    this.detached = false,
    this.empty = false,
  });

  factory GitRepository.fromJson(Map<String, dynamic> json) => GitRepository(
    repositoryId: json['repositoryId']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    headOid: json['headOid']?.toString(),
    currentBranch: json['currentBranch']?.toString(),
    detached: json['detached'] == true,
    empty: json['empty'] == true,
  );
}

class GitBranch {
  final String name;
  final String displayName;
  final String oid;
  final String kind;
  final bool current;
  final String? tracking;
  final int ahead;
  final int behind;

  const GitBranch({
    required this.name,
    required this.displayName,
    required this.oid,
    required this.kind,
    this.current = false,
    this.tracking,
    this.ahead = 0,
    this.behind = 0,
  });

  bool get isLocal => kind == 'local';
  bool get isRemote => kind == 'remote';

  factory GitBranch.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? '';
    final remote = json['remote'] == true || name.startsWith('refs/remotes/');
    final kind = json['kind']?.toString() ?? (remote ? 'remote' : 'local');
    return GitBranch(
      name: name,
      displayName: json['displayName']?.toString() ?? name,
      oid: json['oid']?.toString() ?? '',
      kind: kind,
      current: json['current'] == true,
      tracking: (json['tracking'] ?? json['upstream'])?.toString(),
      ahead: (json['ahead'] as num?)?.toInt() ?? 0,
      behind: (json['behind'] as num?)?.toInt() ?? 0,
    );
  }
}

class GitGraphTip {
  final String name;
  final String tipOid;

  const GitGraphTip({required this.name, required this.tipOid});

  factory GitGraphTip.fromJson(Map<String, dynamic> json) => GitGraphTip(
    name: json['name']?.toString() ?? '',
    tipOid: json['tipOid']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {'name': name, 'tipOid': tipOid};
}

class GitCommitSummary {
  final String oid;
  final List<String> parents;
  final String author;
  final int timestamp;
  final String subject;
  final List<String> refs;
  final List<String> tags;

  const GitCommitSummary({
    required this.oid,
    this.parents = const [],
    this.author = '',
    this.timestamp = 0,
    this.subject = '',
    this.refs = const [],
    this.tags = const [],
  });

  factory GitCommitSummary.fromJson(Map<String, dynamic> json) =>
      GitCommitSummary(
        oid: json['oid']?.toString() ?? '',
        parents: _strings(json['parents']),
        author: json['author']?.toString() ?? '',
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        subject: json['subject']?.toString() ?? '',
        refs: _strings(json['refs']),
        tags: _strings(json['tags']),
      );
}

class GitGraphPage {
  final List<GitCommitSummary> commits;
  final String? snapshotId;
  final String? nextCursor;
  final List<GitGraphTip> tips;

  const GitGraphPage({
    this.commits = const [],
    this.snapshotId,
    this.nextCursor,
    this.tips = const [],
  });

  factory GitGraphPage.fromJson(Map<String, dynamic> json) => GitGraphPage(
    commits: List.unmodifiable(
      (json['commits'] as List? ?? const []).whereType<Map>().map(
        (item) => GitCommitSummary.fromJson(Map<String, dynamic>.from(item)),
      ),
    ),
    snapshotId: json['snapshotId']?.toString(),
    nextCursor: json['nextCursor']?.toString(),
    tips: List.unmodifiable(
      (json['tips'] as List? ?? const []).whereType<Map>().map(
        (item) => GitGraphTip.fromJson(Map<String, dynamic>.from(item)),
      ),
    ),
  );
}

class GitCommitStats {
  final int additions;
  final int deletions;
  final int files;

  const GitCommitStats({
    this.additions = 0,
    this.deletions = 0,
    this.files = 0,
  });

  factory GitCommitStats.fromJson(Map<String, dynamic>? json) => GitCommitStats(
    additions: (json?['additions'] as num?)?.toInt() ?? 0,
    deletions: (json?['deletions'] as num?)?.toInt() ?? 0,
    files: (json?['files'] as num?)?.toInt() ?? 0,
  );
}

class GitCommitFile {
  final String path;
  final String? oldPath;
  final String status;
  final int additions;
  final int deletions;
  final bool binary;

  const GitCommitFile({
    required this.path,
    this.oldPath,
    this.status = 'modified',
    this.additions = 0,
    this.deletions = 0,
    this.binary = false,
  });

  factory GitCommitFile.fromJson(Map<String, dynamic> json) => GitCommitFile(
    path: json['path']?.toString() ?? '',
    oldPath: json['oldPath']?.toString(),
    status: json['status']?.toString() ?? 'modified',
    additions: (json['additions'] as num?)?.toInt() ?? 0,
    deletions: (json['deletions'] as num?)?.toInt() ?? 0,
    binary: json['binary'] == true,
  );
}

class GitWorktreeFile {
  final String path;
  final String? oldPath;
  final String status;
  final bool conflicted;

  const GitWorktreeFile({
    required this.path,
    this.oldPath,
    this.status = 'modified',
    this.conflicted = false,
  });

  factory GitWorktreeFile.fromJson(Map<String, dynamic> json) =>
      GitWorktreeFile(
        path: json['path']?.toString() ?? '',
        oldPath: json['oldPath']?.toString(),
        status: json['status']?.toString() ?? 'modified',
        conflicted: json['conflicted'] == true,
      );
}

class GitWorktreeSnapshot {
  final String repositoryId;
  final String snapshotId;
  final List<GitWorktreeFile> staged;
  final List<GitWorktreeFile> unstaged;
  final List<GitWorktreeFile> untracked;
  final bool truncated;

  const GitWorktreeSnapshot({
    required this.repositoryId,
    required this.snapshotId,
    this.staged = const [],
    this.unstaged = const [],
    this.untracked = const [],
    this.truncated = false,
  });

  factory GitWorktreeSnapshot.fromJson(Map<String, dynamic> json) {
    List<GitWorktreeFile> files(String key) => List.unmodifiable(
      (json[key] as List? ?? const []).whereType<Map>().map(
        (item) => GitWorktreeFile.fromJson(Map<String, dynamic>.from(item)),
      ),
    );
    return GitWorktreeSnapshot(
      repositoryId: json['repositoryId']?.toString() ?? '',
      snapshotId: json['snapshotId']?.toString() ?? '',
      staged: files('staged'),
      unstaged: files('unstaged'),
      untracked: files('untracked'),
      truncated: json['truncated'] == true,
    );
  }
}

class GitFilePreview {
  final String repositoryId;
  final String kind;
  final String path;
  final String? oldPath;
  final String diff;
  final bool truncated;
  final bool binary;
  final int? additions;
  final int? deletions;
  final String? notice;

  const GitFilePreview({
    required this.repositoryId,
    required this.kind,
    required this.path,
    this.oldPath,
    this.diff = '',
    this.truncated = false,
    this.binary = false,
    this.additions,
    this.deletions,
    this.notice,
  });

  factory GitFilePreview.fromJson(Map<String, dynamic> json) => GitFilePreview(
    repositoryId: json['repositoryId']?.toString() ?? '',
    kind: json['kind']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    oldPath: json['oldPath']?.toString(),
    diff: json['diff']?.toString() ?? '',
    truncated: json['truncated'] == true,
    binary: json['binary'] == true,
    additions: (json['additions'] as num?)?.toInt(),
    deletions: (json['deletions'] as num?)?.toInt(),
    notice: json['notice']?.toString(),
  );
}

class GitCommitDetails {
  final String oid;
  final List<String> parents;
  final String author;
  final int timestamp;
  final String message;
  final List<String> refs;
  final List<String> tags;
  final GitCommitStats stats;
  final List<GitCommitFile> files;
  final int filesTotal;
  final String? filesNextCursor;

  const GitCommitDetails({
    required this.oid,
    this.parents = const [],
    this.author = '',
    this.timestamp = 0,
    this.message = '',
    this.refs = const [],
    this.tags = const [],
    this.stats = const GitCommitStats(),
    this.files = const [],
    this.filesTotal = 0,
    this.filesNextCursor,
  });

  factory GitCommitDetails.fromJson(Map<String, dynamic> json) {
    final filesJson = json['files'];
    final fileItems = filesJson is Map ? filesJson['items'] : filesJson;
    final total = filesJson is Map ? filesJson['total'] : json['filesTotal'];
    final cursor = filesJson is Map
        ? filesJson['nextCursor']
        : json['filesNextCursor'];
    return GitCommitDetails(
      oid: json['oid']?.toString() ?? '',
      parents: _strings(json['parents']),
      author: json['author']?.toString() ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      message: json['message']?.toString() ?? '',
      refs: _strings(json['refs']),
      tags: _strings(json['tags']),
      stats: GitCommitStats.fromJson(
        json['stats'] is Map
            ? Map<String, dynamic>.from(json['stats'] as Map)
            : null,
      ),
      files: List.unmodifiable(
        (fileItems as List? ?? const []).whereType<Map>().map(
          (item) => GitCommitFile.fromJson(Map<String, dynamic>.from(item)),
        ),
      ),
      filesTotal: (total as num?)?.toInt() ?? 0,
      filesNextCursor: cursor?.toString(),
    );
  }

  GitCommitDetails withFiles(List<GitCommitFile> value, String? nextCursor) =>
      GitCommitDetails(
        oid: oid,
        parents: parents,
        author: author,
        timestamp: timestamp,
        message: message,
        refs: refs,
        tags: tags,
        stats: stats,
        files: UnmodifiableListView(value),
        filesTotal: filesTotal,
        filesNextCursor: nextCursor,
      );
}
