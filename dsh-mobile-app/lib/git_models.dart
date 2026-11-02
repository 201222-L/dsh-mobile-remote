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

  /// 宿主是否返回结构化 `refsDetail`/`tagsDetail`（契约 1.1.0+）。
  ///
  /// 旧宿主为 false：图行与提交详情按 legacy `refs`/`tags` 字符串解析兜底。
  bool get refsDetail => features['refsDetail'] == true;

  /// 宿主是否提供文件列表与文件提交历史端点。
  ///
  /// 旧宿主为 false：App 隐藏「提交历史」入口，不请求 `/git/file-history`。
  bool get fileHistory => features['fileHistory'] == true;
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

/// 引用短名归一：去掉 `HEAD -> `、`tag: ` 与 `refs/heads|remotes|tags/` 前缀。
///
/// 旧宿主只返回装饰字符串（如 `HEAD -> refs/heads/main`、`tag: refs/tags/v1`），
/// 结构化宿主返回的 `shortName` 也走同一归一，保证图行与详情展示一致。
String gitShortRefName(String raw) {
  var value = raw.trim();
  if (value.startsWith('HEAD -> ')) value = value.substring(8).trim();
  if (value.startsWith('tag: ')) value = value.substring(5).trim();
  for (final prefix in const [
    'refs/heads/',
    'refs/remotes/',
    'refs/tags/',
  ]) {
    if (value.startsWith(prefix)) {
      value = value.substring(prefix.length);
      break;
    }
  }
  return value.trim();
}

/// 宿主 `refsDetail[].kind` 的稳定取值。
class GitRefKind {
  static const head = 'head';
  static const localBranch = 'localBranch';
  static const remoteBranch = 'remoteBranch';
  static const other = 'other';

  const GitRefKind._();
}

String _normalizeRefKind(Object? value) => switch (value?.toString()) {
  'head' => GitRefKind.head,
  'localBranch' || 'local' || 'branch' => GitRefKind.localBranch,
  'remoteBranch' || 'remote' => GitRefKind.remoteBranch,
  _ => GitRefKind.other,
};

/// 结构化引用（宿主 `refsDetail[]` 的一项；旧宿主由装饰字符串解析得到）。
class GitRefDetail {
  final String kind;
  final String name;
  final String shortName;
  final String oid;
  final bool current;

  const GitRefDetail({
    required this.kind,
    required this.name,
    required this.shortName,
    this.oid = '',
    this.current = false,
  });

  bool get isHead => kind == GitRefKind.head;
  bool get isLocalBranch => kind == GitRefKind.localBranch;
  bool get isRemoteBranch => kind == GitRefKind.remoteBranch;

  /// `refs/stash` 不参与图行/详情展示（宿主契约要求排除）。
  bool get isStash => name == 'refs/stash';

  factory GitRefDetail.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? '';
    final shortName = json['shortName']?.toString();
    return GitRefDetail(
      kind: _normalizeRefKind(json['kind']),
      name: name,
      shortName: gitShortRefName(
        shortName == null || shortName.trim().isEmpty ? name : shortName,
      ),
      oid: json['oid']?.toString() ?? '',
      current: json['current'] == true,
    );
  }
}

/// 宿主 `date` 字段可能是 Unix 秒（num）或 ISO-8601 字符串；解析失败静默为 null。
int? _tagTimestamp(Object? value) {
  if (value is num) return value.toInt();
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  final numeric = int.tryParse(text);
  if (numeric != null) return numeric;
  try {
    return DateTime.parse(text).millisecondsSinceEpoch ~/ 1000;
  } catch (_) {
    return null;
  }
}

/// 结构化 tag（宿主 `tagsDetail[]` 的一项）。
///
/// 图行只保证名称级信息与 [annotated]；提交详情返回 tagger/date/subject。
class GitTagDetail {
  final String name;
  final String shortName;
  final String oid;
  final bool annotated;
  final String? tagger;
  final int? timestamp;
  final String? subject;

  /// 宿主提示：`nested-tag` / `non-commit-target`（仅相关时返回）。
  ///
  /// 元数据读取失败时宿主只回名称 + annotated，不会报错；Hint 同样可缺省。
  final String? hint;

  const GitTagDetail({
    required this.name,
    required this.shortName,
    this.oid = '',
    this.annotated = false,
    this.tagger,
    this.timestamp,
    this.subject,
    this.hint,
  });

  /// 是否带有可展示的 annotated tag 元数据（tagger/日期/说明）。
  bool get hasMetadata =>
      (tagger != null && tagger!.isNotEmpty) ||
      timestamp != null ||
      (subject != null && subject!.isNotEmpty);

  factory GitTagDetail.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? '';
    final shortName = json['shortName']?.toString();
    return GitTagDetail(
      name: name.isEmpty ? (shortName ?? '') : name,
      shortName: gitShortRefName(
        shortName == null || shortName.trim().isEmpty ? name : shortName,
      ),
      oid: json['oid']?.toString() ?? '',
      annotated: json['annotated'] == true,
      tagger: json['tagger']?.toString(),
      timestamp: _tagTimestamp(json['date'] ?? json['timestamp']),
      subject: json['subject']?.toString(),
      hint: json['hint']?.toString(),
    );
  }

  /// 从旧宿主的原始装饰字符串解析（`tag: refs/tags/v1` / `refs/tags/v1` / `v1`）。
  factory GitTagDetail.fromLegacy(String raw) {
    final text = raw.trim();
    final fullName = text.startsWith('tag: ')
        ? text.substring(5).trim()
        : (text.startsWith('refs/tags/') ? text : '');
    final shortName = gitShortRefName(text);
    return GitTagDetail(
      name: fullName.isEmpty ? shortName : fullName,
      shortName: shortName,
    );
  }
}

/// 一个提交上的引用与 tag 集合。
///
/// 优先使用宿主结构化 `refsDetail`/`tagsDetail`；任一列表缺失时回退到 legacy
/// `refs`/`tags` 字符串解析（旧宿主兼容，且图行与提交详情共用同一适配）。
class GitDecoration {
  final List<GitRefDetail> refs;
  final List<GitTagDetail> tags;

  const GitDecoration({this.refs = const [], this.tags = const []});

  static const empty = GitDecoration();

  bool get isEmpty => refs.isEmpty && tags.isEmpty;
  bool get isNotEmpty => !isEmpty;

  factory GitDecoration.fromJson(Map<String, dynamic> json) {
    final legacy = GitDecoration.fromLegacy(
      refs: _strings(json['refs']),
      tags: _strings(json['tags']),
    );
    final structuredRefs = List<GitRefDetail>.unmodifiable(
      (json['refsDetail'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => GitRefDetail.fromJson(Map<String, dynamic>.from(item)),
          ),
    );
    final structuredTags = List<GitTagDetail>.unmodifiable(
      (json['tagsDetail'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => GitTagDetail.fromJson(Map<String, dynamic>.from(item)),
          ),
    );
    return GitDecoration(
      refs: structuredRefs.isEmpty ? legacy.refs : structuredRefs,
      tags: structuredTags.isEmpty ? legacy.tags : structuredTags,
    );
  }

  factory GitDecoration.fromLegacy({
    List<String> refs = const [],
    List<String> tags = const [],
  }) {
    final parsedRefs = <GitRefDetail>[];
    final parsedTags = <GitTagDetail>[];
    for (final raw in refs) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      if (text.startsWith('tag: ') || text.startsWith('refs/tags/')) {
        parsedTags.add(GitTagDetail.fromLegacy(text));
      } else if (text.startsWith('HEAD -> ')) {
        final target = text.substring(8).trim();
        final targetShortName = gitShortRefName(target);
        // 与宿主 legacy 投影一致：HEAD 自身作为 head 标签（name/shortName 均为
        // HEAD），目标分支另投影为 current localBranch。两者不能共用 shortName，
        // 否则旧宿主的图行/Refs 行会出现重复的 “main” pill。
        parsedRefs.add(
          const GitRefDetail(
            kind: GitRefKind.head,
            name: 'HEAD',
            shortName: 'HEAD',
            current: true,
          ),
        );
        if (targetShortName.isNotEmpty) {
          parsedRefs.add(
            GitRefDetail(
              kind: GitRefKind.localBranch,
              name: target.startsWith('refs/heads/')
                  ? target
                  : 'refs/heads/$targetShortName',
              shortName: targetShortName,
              current: true,
            ),
          );
        }
      } else if (text == 'HEAD') {
        parsedRefs.add(
          const GitRefDetail(
            kind: GitRefKind.head,
            name: 'HEAD',
            shortName: 'HEAD',
            current: true,
          ),
        );
      } else if (text.startsWith('refs/heads/')) {
        parsedRefs.add(
          GitRefDetail(
            kind: GitRefKind.localBranch,
            name: text,
            shortName: gitShortRefName(text),
          ),
        );
      } else if (text.startsWith('refs/remotes/')) {
        parsedRefs.add(
          GitRefDetail(
            kind: GitRefKind.remoteBranch,
            name: text,
            shortName: gitShortRefName(text),
          ),
        );
      } else {
        // 旧宿主的图行可能直接返回 `main` / `origin/other` 这类短装饰。
        parsedRefs.add(
          GitRefDetail(
            kind: text.contains('/')
                ? GitRefKind.other
                : GitRefKind.localBranch,
            name: text,
            shortName: gitShortRefName(text),
          ),
        );
      }
    }
    final seenTags = <String>{};
    for (final raw in tags) {
      final tag = GitTagDetail.fromLegacy(raw);
      if (tag.shortName.isNotEmpty && seenTags.add(tag.shortName)) {
        parsedTags.add(tag);
      }
    }
    // `refs` 里的 tag 装饰与 `tags` 数组合并去重（同一 tag 只展示一次）。
    final seenRefTags = <String>{};
    final dedupedTags = <GitTagDetail>[
      for (final tag in parsedTags)
        if (tag.shortName.isNotEmpty && seenRefTags.add(tag.shortName)) tag,
    ];
    return GitDecoration(
      refs: List.unmodifiable(parsedRefs),
      tags: List.unmodifiable(dedupedTags),
    );
  }
}

class GitCommitSummary {
  final String oid;
  final List<String> parents;
  final String author;
  final int timestamp;
  final String subject;
  final List<String> refs;
  final List<String> tags;

  /// 结构化引用（宿主 1.1.0+）；旧宿主由 [refs]/[tags] 字符串兜底解析。
  final GitDecoration decoration;

  const GitCommitSummary({
    required this.oid,
    this.parents = const [],
    this.author = '',
    this.timestamp = 0,
    this.subject = '',
    this.refs = const [],
    this.tags = const [],
    this.decoration = GitDecoration.empty,
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
        decoration: GitDecoration.fromJson(json),
      );

  /// 结构化数据缺失（如直接构造的旧宿主模型）时由 legacy 字符串派生。
  GitDecoration get resolvedDecoration =>
      decoration.isEmpty && (refs.isNotEmpty || tags.isNotEmpty)
      ? GitDecoration.fromLegacy(refs: refs, tags: tags)
      : decoration;
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

  /// 结构化引用与 tag（宿主 1.1.0+）；旧宿主由 [refs]/[tags] 字符串兜底解析。
  final GitDecoration decoration;

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
    this.decoration = GitDecoration.empty,
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
      decoration: GitDecoration.fromJson(json),
    );
  }

  /// 结构化数据缺失（如直接构造的旧宿主模型）时由 legacy 字符串派生。
  GitDecoration get resolvedDecoration =>
      decoration.isEmpty && (refs.isNotEmpty || tags.isNotEmpty)
      ? GitDecoration.fromLegacy(refs: refs, tags: tags)
      : decoration;

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
        decoration: decoration,
      );
}

/// `GET /api/git/files` 的已跟踪文件列表（HEAD 视角）。
class GitFileList {
  /// 仓库相对路径，已按宿主规则排序。
  final List<String> files;

  /// 是否因安全上限被截断（无 q 时最多 200 条）。
  final bool truncated;

  /// 不可用原因（如 `not-a-repository`）；正常为空。
  final String? reason;

  const GitFileList({this.files = const [], this.truncated = false, this.reason});

  factory GitFileList.fromJson(Map<String, dynamic> json) {
    final raw = json['files'] ?? json['items'];
    return GitFileList(
      files: List.unmodifiable(
        (raw as List? ?? const [])
            .map(
              (item) => item is Map
                  ? (item['path']?.toString() ?? '')
                  : item.toString(),
            )
            .where((path) => path.isNotEmpty),
      ),
      truncated: json['truncated'] == true,
      reason: json['reason']?.toString(),
    );
  }
}

/// 文件提交历史的一行（`/api/git/file-history` 的 `entries[]`）。
class GitFileHistoryEntry {
  final String oid;
  final String shortOid;
  final String author;
  final int timestamp;
  final String subject;

  /// 该文件在这个提交上的状态：M/A/D/R（宿主原始判定，App 只展示）。
  final String status;

  const GitFileHistoryEntry({
    required this.oid,
    this.shortOid = '',
    this.author = '',
    this.timestamp = 0,
    this.subject = '',
    this.status = 'M',
  });

  factory GitFileHistoryEntry.fromJson(Map<String, dynamic> json) {
    final oid = json['oid']?.toString() ?? '';
    return GitFileHistoryEntry(
      oid: oid,
      shortOid: json['shortOid']?.toString() ??
          (oid.length <= 8 ? oid : oid.substring(0, 8)),
      author: json['author']?.toString() ?? '',
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      subject: json['subject']?.toString() ?? '',
      status: json['status']?.toString() ?? 'M',
    );
  }
}

/// `GET /api/git/file-history` 的分页结果。
///
/// 空/异常情况宿主仍返回 200：用 [reason] 区分 `not-tracked` / `no-history` /
/// `path-invalid`，避免客户端把 404 当业务状态猜。
class GitFileHistoryPage {
  final String repositoryId;
  final String path;
  final List<GitFileHistoryEntry> entries;
  final String? nextCursor;

  /// 是否因上限（5000 条 / 20 秒软超时）只返回部分记录。
  final bool truncated;
  final String? reason;

  const GitFileHistoryPage({
    this.repositoryId = '',
    this.path = '',
    this.entries = const [],
    this.nextCursor,
    this.truncated = false,
    this.reason,
  });

  factory GitFileHistoryPage.fromJson(Map<String, dynamic> json) =>
      GitFileHistoryPage(
        repositoryId: json['repositoryId']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        entries: List.unmodifiable(
          (json['entries'] as List? ?? const []).whereType<Map>().map(
            (item) =>
                GitFileHistoryEntry.fromJson(Map<String, dynamic>.from(item)),
          ),
        ),
        nextCursor: json['nextCursor']?.toString(),
        truncated: json['truncated'] == true,
        reason: json['reason']?.toString(),
      );
}
