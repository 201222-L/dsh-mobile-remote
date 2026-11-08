// issue #53（ADR 0027 §3、docs/03-api.md §6.20–§6.23）：轮末产出物的纯逻辑层。
//
// 这里只做**纯 Dart**投影，不依赖 Flutter：
// - 轮末信号 `Tail`/`turnTails` 与能力位；
// - 改动摘要/单文件对比/交付文件的 wire 模型；
// - 按坐标（sessionId, kind, seq, index）寻址的文件坐标与记录内路径匹配；
// - 懒加载用的负结果短 TTL 缓存。
//
// ChatScreen 与预览/差异页共用同一判据，widget/unit 测试可直接驱动，不在 UI 里复刻规则。

/// 轮末信号：某轮是否存在改动文件 / 交付文件。
///
/// 来源：`GET /m/api/history` 的 `turnTails["<turn>"]` 与实时 `turn/end` 摘要的
/// `data.tail`（docs/03-api.md §6.20）。两个字段都可能缺省（旧插件），此时不渲染卡片。
class TurnTail {
  final bool changes;
  final bool presented;

  const TurnTail({this.changes = false, this.presented = false});

  bool get visible => changes || presented;

  static TurnTail? fromJson(Object? json) {
    if (json is! Map) return null;
    final changes = json['changes'] == true;
    final presented = json['presented'] == true;
    if (!changes && !presented) return null;
    return TurnTail(changes: changes, presented: presented);
  }

  @override
  bool operator ==(Object other) =>
      other is TurnTail &&
      other.changes == changes &&
      other.presented == presented;

  @override
  int get hashCode => Object.hash(changes, presented);

  @override
  String toString() => 'TurnTail(changes: $changes, presented: $presented)';
}

/// 解析 `/history` 的 `turnTails` 增量（key 为轮号字符串，§6.20）。
Map<int, TurnTail> turnTailsFromJson(Object? json) {
  final out = <int, TurnTail>{};
  if (json is! Map) return out;
  json.forEach((key, value) {
    final turn = int.tryParse('$key');
    final tail = TurnTail.fromJson(value);
    if (turn != null && turn >= 0 && tail != null) out[turn] = tail;
  });
  return out;
}

/// 轮末文件的两类记录来源：交付文件声明 / 本轮改动文件。
enum TurnFileKind { presented, changed }

/// 预览/下载的**唯一**寻址方式：会话 + 记录来源 + 事件序号 + 下标。
///
/// 客户端不允许给路径（GitLab #16 收紧方向 / §6.23）：路径由服务端从会话记录解析。
class TurnFileCoordinate {
  final String sessionId;
  final TurnFileKind kind;
  final int seq;
  final int index;

  const TurnFileCoordinate({
    required this.sessionId,
    required this.kind,
    required this.seq,
    required this.index,
  });

  /// 服务端查询参数用的小写 kind（`presented` / `changed`）。
  String get kindParam => kind == TurnFileKind.presented ? 'presented' : 'changed';

  @override
  bool operator ==(Object other) =>
      other is TurnFileCoordinate &&
      other.sessionId == sessionId &&
      other.kind == kind &&
      other.seq == seq &&
      other.index == index;

  @override
  int get hashCode => Object.hash(sessionId, kind, seq, index);

  @override
  String toString() =>
      'TurnFileCoordinate($sessionId, ${kind.name}, seq: $seq, index: $index)';
}

/// 交付文件声明（`deliverables/presented` 摘要 data.files 的元素）。
///
/// 服务端只下发 name/display/description（§6.20）；[seq]/[index] 是 App 侧补上的
/// 预览坐标（事件序号 + 该事件文件数组下标），不是 wire 字段。
class DeliverableFile {
  final String name;
  final String display;
  final String? description;
  final int seq;
  final int index;

  /// 服务端下发的**不泄路径稳定身份**（路径摘要）。旧服务端/旧事件可能缺省。
  final String? id;

  const DeliverableFile({
    required this.name,
    required this.display,
    this.description,
    required this.seq,
    required this.index,
    this.id,
  });

  /// 同轮多次 present 的去重键（issue #60 R08）：
  /// - 有稳定 id：同一文件跨声明合并；
  /// - 无 id：只能用坐标作身份，**保守保留多条**（display 是脱敏展示值，不同目录
  ///   同名文件可能相同，不能拿它当唯一身份静默丢掉合法坐标）。
  String get dedupeKey => id != null && id!.isNotEmpty
      ? 'id:$id'
      : 'coord:$seq:$index';
}

/// 从 `deliverables/presented` 摘要 data 解析交付文件（保持事件内下标）。
List<DeliverableFile> deliverableFilesOf(
  int? eventSeq,
  Map<String, dynamic>? data,
) {
  final raw = data?['files'];
  if (raw is! List) return const [];
  final out = <DeliverableFile>[];
  for (var index = 0; index < raw.length; index += 1) {
    final item = raw[index];
    if (item is! Map) continue;
    final name = (item['name'] ?? '').toString();
    final display = (item['display'] ?? '').toString();
    if (name.isEmpty && display.isEmpty) continue;
    final description = item['description'];
    out.add(
      DeliverableFile(
        name: name.isNotEmpty ? name : display,
        display: display.isNotEmpty ? display : name,
        description: description is String && description.trim().isNotEmpty
            ? description
            : null,
        seq: eventSeq ?? 0,
        index: index,
        id: (item['id'] ?? '').toString().isNotEmpty
            ? item['id'].toString()
            : null,
      ),
    );
  }
  return out;
}

/// 同轮多次 `present` 的合并：按路径去重、说明取该轮**最后一次**声明（§6.20）。
///
/// issue #60 R07：历史回放是倒序/分页到达的，"最后一次声明"必须按**持久坐标**
/// (seq, index) 判定，而不是按到达顺序覆盖；实时/初载/补页因此收敛到同一结果。
/// 输出按 (seq, index) 升序，保证不同到达顺序得到相同列表。
List<DeliverableFile> mergeDeliverableDeclarations(
  List<DeliverableFile> existing,
  List<DeliverableFile> incoming,
) {
  final merged = <String, DeliverableFile>{};
  void absorb(DeliverableFile file) {
    final current = merged[file.dedupeKey];
    if (current == null || _isLaterDeclaration(file, current)) {
      merged[file.dedupeKey] = file;
    }
  }

  for (final file in existing) {
    absorb(file);
  }
  for (final file in incoming) {
    absorb(file);
  }
  final out = merged.values.toList(growable: false)
    ..sort((a, b) {
      final bySeq = a.seq.compareTo(b.seq);
      return bySeq != 0 ? bySeq : a.index.compareTo(b.index);
    });
  return List.unmodifiable(out);
}

/// 持久坐标更晚（seq 优先、同 seq 比 index）的声明胜出。
bool _isLaterDeclaration(DeliverableFile candidate, DeliverableFile current) {
  if (candidate.seq != current.seq) return candidate.seq > current.seq;
  return candidate.index > current.index;
}

/// 本轮改动文件（`/changes/summary` 的 `files[]`，§6.21）。
class ChangedFile {
  final int seq;
  final int index;
  final String display;
  final String name;
  final int added;
  final int deleted;
  final bool binary;
  final bool oversized;

  /// issue #60 round4-2：服务端路径摘要身份（与 presented 同一 helper）；旧插件缺省。
  final String? id;

  const ChangedFile({
    required this.seq,
    required this.index,
    required this.display,
    required this.name,
    required this.added,
    required this.deleted,
    this.binary = false,
    this.oversized = false,
    this.id,
  });

  static ChangedFile? fromJson(Object? json) {
    if (json is! Map) return null;
    final display = (json['display'] ?? '').toString();
    final name = (json['name'] ?? '').toString();
    if (display.isEmpty && name.isEmpty) return null;
    return ChangedFile(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      index: (json['index'] as num?)?.toInt() ?? 0,
      display: display,
      name: name.isNotEmpty ? name : display,
      added: (json['added'] as num?)?.toInt() ?? 0,
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      binary: json['binary'] == true,
      oversized: json['oversized'] == true,
      id: (json['id'] ?? '').toString().isNotEmpty ? json['id'].toString() : null,
    );
  }
}

/// `/changes/summary` 的三态结果（§6.21）：服务不可用**不抛异常**，统一降级。
enum ChangesState { available, absent, unavailable }

class ChangesSummary {
  final ChangesState state;
  final int turn;
  final List<ChangedFile> files;
  final int total;
  final int added;
  final int deleted;
  final bool truncated;

  const ChangesSummary({
    required this.state,
    required this.turn,
    this.files = const [],
    this.total = 0,
    this.added = 0,
    this.deleted = 0,
    this.truncated = false,
  });

  static const ChangesSummary unavailable = ChangesSummary(
    state: ChangesState.unavailable,
    turn: 0,
  );

  bool get hasFiles => state == ChangesState.available && files.isNotEmpty;

  factory ChangesSummary.fromJson(Map<String, dynamic> json) {
    final stateText = json['state'];
    final state = switch (stateText) {
      'available' => ChangesState.available,
      'absent' => ChangesState.absent,
      _ => ChangesState.unavailable,
    };
    final files = <ChangedFile>[];
    final raw = json['files'];
    if (raw is List) {
      for (final item in raw) {
        final file = ChangedFile.fromJson(item);
        if (file != null) files.add(file);
      }
    }
    return ChangesSummary(
      state: state,
      turn: (json['turn'] as num?)?.toInt() ?? 0,
      files: files,
      total: (json['total'] as num?)?.toInt() ?? files.length,
      added: (json['added'] as num?)?.toInt() ?? 0,
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      truncated: json['truncated'] == true,
    );
  }
}

/// `/changes/diff` 的单文件对比（§6.22）：text 给统一 diff 文本，binary/oversized
/// 只给不可比对提示。
class ChangesDiff {
  final String kind;
  final String display;
  final bool before;
  final bool after;
  final bool coarse;
  final String diff;
  final bool truncated;

  const ChangesDiff({
    required this.kind,
    required this.display,
    this.before = true,
    this.after = true,
    this.coarse = false,
    this.diff = '',
    this.truncated = false,
  });

  bool get isBinary => kind == 'binary';
  bool get isOversized => kind == 'oversized';
  bool get isText => kind == 'text';

  factory ChangesDiff.fromJson(Map<String, dynamic> json) {
    return ChangesDiff(
      kind: (json['kind'] ?? 'text').toString(),
      display: (json['display'] ?? '').toString(),
      before: json['before'] != false,
      after: json['after'] != false,
      coarse: json['coarse'] == true,
      diff: (json['diff'] ?? '').toString(),
      truncated: json['truncated'] == true,
    );
  }
}

/// 可内联预览的图片扩展名（issue #53 §5：png/jpg/webp/gif）。
const imagePreviewExtensions = <String>{'png', 'jpg', 'jpeg', 'webp', 'gif'};

/// 文件名是否指向可直接图片预览的格式。
bool isPreviewableImageName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  return imagePreviewExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// 记录内路径 → 预览坐标的行内链接解析器（§6.20 末尾 / issue #53 §6）。
///
/// 规则：**精确路径优先**（display / name 精确匹配），唯一 basename 次之，
/// 有歧义或未记录一律不链接（不猜测、不链接未记录文件）。
class TurnFileLinkResolver {
  /// issue #60 round4-2（R08）：display 是脱敏展示值，不能当文件身份。按**逻辑身份**
  /// （优先服务端路径摘要 id；旧数据用 kind+seq+index 兼容）分组：
  /// - 同一 display 下所有候选同一 logicalId → 合并为一个逻辑文件（代表坐标优先 presented，
  ///   其次更大 (seq,index)），可链接；
  /// - 同 display 出现不同 logicalId（不同目录同名文件）→ 歧义返回 null。
  final Map<String, List<_LinkCandidate>> _exact = {};
  final Map<String, List<_LinkCandidate>> _byBasename = {};

  TurnFileLinkResolver({
    required String sessionId,
    required List<DeliverableFile> presented,
    List<ChangedFile> changed = const [],
  }) {
    for (final file in presented) {
      _add(file.display, file.name, file.id, TurnFileCoordinate(
        sessionId: sessionId,
        kind: TurnFileKind.presented,
        seq: file.seq,
        index: file.index,
      ));
    }
    for (final file in changed) {
      _add(file.display, file.name, file.id, TurnFileCoordinate(
        sessionId: sessionId,
        kind: TurnFileKind.changed,
        seq: file.seq,
        index: file.index,
      ));
    }
  }

  bool get isEmpty => _exact.isEmpty;

  static String _normalize(String value) {
    var text = value.trim();
    while (text.startsWith('./')) {
      text = text.substring(2);
    }
    return text;
  }

  static String _basenameOf(String value) {
    final text = _normalize(value);
    final slash = text.lastIndexOf('/');
    return slash >= 0 ? text.substring(slash + 1) : text;
  }

  void _add(String display, String name, String? serverId, TurnFileCoordinate coordinate) {
    final path = _normalize(display);
    final candidate = _LinkCandidate(
      coordinate: coordinate,
      serverId: serverId != null && serverId.isNotEmpty ? serverId : null,
    );
    if (path.isNotEmpty) {
      _exact.putIfAbsent(path, () => <_LinkCandidate>[]).add(candidate);
    }
    final rawName = _normalize(name);
    if (rawName.isNotEmpty) {
      final base = _basenameOf(path.isNotEmpty ? path : rawName);
      if (base.isNotEmpty) {
        _byBasename.putIfAbsent(base, () => <_LinkCandidate>[]).add(candidate);
      }
      final nameBase = _basenameOf(rawName);
      if (nameBase.isNotEmpty && nameBase != base) {
        _byBasename.putIfAbsent(nameBase, () => <_LinkCandidate>[]).add(candidate);
      }
    }
  }

  /// 行内代码文本 → 预览坐标；未命中/存在不同逻辑文件歧义返回 null。
  TurnFileCoordinate? resolve(String code) {
    final token = _normalize(code);
    if (token.isEmpty) return null;
    final exact = _exact[token];
    if (exact != null) {
      return _resolveCandidates(exact, legacyExactDisplayMerge: true);
    }
    return _resolveCandidates(_byBasename[_basenameOf(token)]);
  }

  TurnFileCoordinate? _resolveCandidates(
    List<_LinkCandidate>? candidates, {
    bool legacyExactDisplayMerge = false,
  }) {
    if (candidates == null || candidates.isEmpty) return null;
    final withId = candidates.where((c) => c.serverId != null).toList();
    if (withId.length == candidates.length) {
      final ids = withId.map((c) => c.serverId!).toSet();
      if (ids.length != 1) return null;
      return _representative(candidates);
    }
    if (withId.isNotEmpty) {
      // 新旧混合：无法证明是同一文件，保守不链接。
      return null;
    }
    // 旧数据无 id：**仅精确 display 命中**时，presented + changed 可保守视作同一逻辑
    // 文件；basename 命中不同路径的同名文件仍按歧义处理（不跨路径合并）。
    if (legacyExactDisplayMerge) {
      final hasPresented = candidates.any((c) => c.coordinate.kind == TurnFileKind.presented);
      final hasChanged = candidates.any((c) => c.coordinate.kind == TurnFileKind.changed);
      if (hasPresented && hasChanged) return _representative(candidates);
    }
    return candidates.length == 1 ? candidates.single.coordinate : null;
  }

  /// 代表坐标：presented 优先；同类取更大 (seq,index)。
  static TurnFileCoordinate _representative(List<_LinkCandidate> candidates) {
    final sorted = [...candidates]..sort((a, b) {
      final aPresented = a.coordinate.kind == TurnFileKind.presented;
      final bPresented = b.coordinate.kind == TurnFileKind.presented;
      if (aPresented != bPresented) return aPresented ? -1 : 1;
      final bySeq = b.coordinate.seq.compareTo(a.coordinate.seq);
      return bySeq != 0 ? bySeq : b.coordinate.index.compareTo(a.coordinate.index);
    });
    return sorted.first.coordinate;
  }
}

class _LinkCandidate {
  const _LinkCandidate({required this.coordinate, this.serverId});
  final TurnFileCoordinate coordinate;
  final String? serverId;
}

/// 改动摘要的负结果短 TTL 缓存（issue #53 §7）。
///
/// `absent`/`unavailable` 只缓存很短时间（避免"宿主重启后短暂窗口"永久不显示卡片），
/// `available` 缓存稍长；宿主重启/轮末信号变化时调用方 `clear()`。
class TurnTailSummaryCache {
  TurnTailSummaryCache({
    this.negativeTtl = const Duration(seconds: 60),
    this.availableTtl = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration negativeTtl;
  final Duration availableTtl;

  /// 时钟注入：仅用于测试 TTL（widget 测试的假时钟不会推进 `DateTime.now()`）。
  final DateTime Function() _clock;
  final Map<int, _CachedSummary> _entries = {};

  ChangesSummary? lookup(int turn) {
    final entry = _entries[turn];
    if (entry == null) return null;
    if (entry.expiresAt.isBefore(_clock())) {
      _entries.remove(turn);
      return null;
    }
    return entry.summary;
  }

  void store(int turn, ChangesSummary summary) {
    final ttl = summary.state == ChangesState.available
        ? availableTtl
        : negativeTtl;
    _entries[turn] = _CachedSummary(summary, _clock().add(ttl));
  }

  void clear() => _entries.clear();
}

class _CachedSummary {
  final ChangesSummary summary;
  final DateTime expiresAt;
  const _CachedSummary(this.summary, this.expiresAt);
}
