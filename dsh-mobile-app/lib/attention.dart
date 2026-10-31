// 通知身份 / 去重 / 撤销的纯逻辑层（M1a）。
//
// 背景：现有实现用 `sessionId.hashCode` 当通知 id——同一会话的第二条审批会覆盖第一条，
// 且 `String.hashCode` 在 Dart VM 上按进程加盐，跨进程不稳定，撤销必然失败。
//
// 这一层只做三件事，全部可单测、不碰 IO：
//   1. 身份：`key = kind|sessionId|identity`，identity 取 approvalId，缺失时退 rpcId；
//   2. id：FNV-1a 派生，落在 [0x1000, 0x3FFFFFFF]，避开保活/宠物占用的低位号段；
//   3. 判据：纯函数 `decideAttention`，输入事件 + 快照，输出「走系统通知 / 走横幅」。
//
// 有状态的部分（去重占位、撤销、对账）在 `AttentionLedger`，它是**唯一写者**，
// 由调用方串行使用；持久化交给调用方（SharedPreferences），本层只提供序列化。

import 'dart:math' as math;

/// 通知种类。完成类（turn/end）**不在**范围内：它每轮都发，含子代理与中止，
/// 做成通知会退化成上一版的「横幅 37 条」。
enum AttentionKind {
  approval('approval'),
  question('question');

  const AttentionKind(this.wire);
  final String wire;

  static AttentionKind? tryParse(String? v) {
    for (final k in values) {
      if (k.wire == v) return k;
    }
    return null;
  }
}

/// 一条需要用户处理的事件（审批或问询）。
class AttentionEvent {
  const AttentionEvent({
    required this.kind,
    required this.sessionId,
    required this.identity,
    required this.at,
    this.toolName,
    this.summary,
    this.isReplay = false,
  });

  final AttentionKind kind;
  final String sessionId;

  /// approvalId（审批）或 questionRpcId / questionId（问询）；不得为空。
  final String identity;

  final DateTime at;
  final String? toolName;

  /// 审批的 reason 或问询的第一句问题，用于通知正文。
  final String? summary;

  /// 插件重连时会回放未结算帧（带原始 `at`），回放帧不应重复提醒。
  final bool isReplay;

  String get key => attentionKey(
    kind: kind.wire,
    sessionId: sessionId,
    identity: identity,
  );

  int get notificationId => stableNotificationId(key);

  @override
  String toString() => 'AttentionEvent($key, at=${at.toIso8601String()})';
}

/// 稳定身份键。`kind` 必须在最前面：approval 与 question 的 rpcId 是两个命名空间。
String attentionKey({
  required String kind,
  required String sessionId,
  required String identity,
}) => '$kind|$sessionId|$identity';

/// 业务通知 id 的起始号段。
///
/// 低位号段留给「保活常驻通知」和「悬浮球/宠物」等系统通知（历史值 `0xDBB`）。
/// 从 `0x1000` 起算，天然避开 `0xDBB`；上限 `0x3FFFFFFF` 保证不会撞到 int32 负数。
const int attentionIdBase = 0x1000;
const int attentionIdSpan = 0x3FFFF000;

/// 由 key 派生通知 id：同一 key 在任何进程、任何时候都得到同一个 id。
///
/// 注意：**不要**写成 `fnv1a % 0x40000000`——取模不会排除保留段 `0xDBB`，
/// 必须靠「基址 + 小跨度」来保证值域不重叠。
int stableNotificationId(String key) =>
    attentionIdBase + (fnv1a32(key) % attentionIdSpan);

/// FNV-1a 32 位哈希（Dart 的 int 是 64 位，每步要掩回 32 位）。
int fnv1a32(String text) {
  var hash = 0x811C9DC5;
  for (final unit in text.codeUnits) {
    hash ^= unit & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
    if (unit > 0xFF) {
      // 非拉丁字符按高位字节再混一次，避免中文/emoji 只取低字节导致的碰撞。
      hash ^= (unit >> 8) & 0xFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
  }
  return hash;
}

/// App 处于什么状态（只取与通知决策相关的粒度）。
enum AppPhase { foreground, inactive, background, unknown }

/// 决策需要的快照。由调用方在**一个地方**采集，Policy 不做任何 IO。
class AttentionSnapshot {
  const AttentionSnapshot({
    required this.phase,
    required this.permissionGranted,
    required this.channelEnabled,
    this.visibleSession,
    this.quietHours = false,
  });

  final AppPhase phase;

  /// `areNotificationsEnabled()` 的结果。
  final bool permissionGranted;

  /// 通知渠道 importance != IMPORTANCE_NONE（用户可单独静音）。
  final bool channelEnabled;

  /// 当前正被用户看着的会话（聊天页在栈顶时为非 null）。
  final String? visibleSession;

  /// 安静时段（本轮不做，预留）。
  final bool quietHours;
}

/// 决策结果。`reason` 只用于日志与诊断，不参与业务。
class ChannelDecision {
  const ChannelDecision({
    required this.system,
    required this.banner,
    required this.reason,
  });

  final bool system;
  final bool banner;
  final String reason;

  bool get any => system || banner;

  @override
  String toString() => 'ChannelDecision(system=$system, banner=$banner, $reason)';
}

/// 纯函数判据：同一条事件应该走哪些通道。
///
/// 与通道矩阵一一对应：
/// - 前台且正看着该会话 → 只有横幅（应用内已有卡片）；
/// - 前台其它页面 → 系统通知 + 横幅；
/// - 后台 → 只系统通知（横幅看不见）；
/// - 无权限/渠道被静音 → 系统通知不发，横幅照旧（否则用户完全无感）。
ChannelDecision decideAttention(
  AttentionEvent event,
  AttentionSnapshot snapshot, {
  required bool seenRecently,
}) {
  final isViewing =
      snapshot.phase == AppPhase.foreground &&
      snapshot.visibleSession != null &&
      snapshot.visibleSession == event.sessionId;

  final permissionOk = snapshot.permissionGranted && snapshot.channelEnabled;

  if (seenRecently && !event.isReplay) {
    // 同一 key 近期已经提醒过：不再发系统通知，横幅也不重复弹。
    return const ChannelDecision(
      system: false,
      banner: false,
      reason: 'dedupe',
    );
  }

  if (isViewing) {
    return const ChannelDecision(
      system: false,
      banner: true,
      reason: 'viewing-session',
    );
  }

  if (!permissionOk) {
    return const ChannelDecision(
      system: false,
      banner: true,
      reason: 'no-permission',
    );
  }

  if (snapshot.phase == AppPhase.background) {
    return const ChannelDecision(
      system: true,
      banner: false,
      reason: 'background',
    );
  }

  if (snapshot.quietHours) {
    return const ChannelDecision(
      system: false,
      banner: false,
      reason: 'quiet-hours',
    );
  }

  return ChannelDecision(
    system: true,
    banner: true,
    reason: snapshot.phase == AppPhase.foreground ? 'foreground' : 'inactive',
  );
}

/// 条目状态。`blocked` 与 `dismissed` 必须分开：前者是"系统层面发不出去"，
/// 后者是"用户/系统把它清掉了"——混用会在对账时把"权限被拒"误判成"用户划掉"。
enum AttentionStatus {
  active,
  blocked,
  dismissed,
  resolved;

  static AttentionStatus fromName(String? v) {
    for (final s in values) {
      if (s.name == v) return s;
    }
    return active;
  }
}

/// ledger 里的一条记录。
class AttentionEntry {
  AttentionEntry({
    required this.key,
    required this.id,
    required this.kind,
    required this.sessionId,
    required this.at,
    this.status = AttentionStatus.active,
  });

  final String key;
  final int id;
  final AttentionKind kind;
  final String sessionId;
  final DateTime at;
  AttentionStatus status;

  Map<String, dynamic> toJson() => {
    'key': key,
    'id': id,
    'kind': kind.wire,
    'sessionId': sessionId,
    'at': at.millisecondsSinceEpoch,
    'status': status.name,
  };

  static AttentionEntry? fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    final id = json['id'];
    final kind = AttentionKind.tryParse(json['kind'] as String?);
    final sessionId = json['sessionId'];
    final at = json['at'];
    if (key is! String || id is! int || kind == null || sessionId is! String) {
      return null;
    }
    return AttentionEntry(
      key: key,
      id: id,
      kind: kind,
      sessionId: sessionId,
      at: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
      status: AttentionStatus.fromName(json['status'] as String?),
    );
  }
}

/// 去重与撤销的唯一写者。
///
/// 关键约束：
/// - `reserve` 是**原子占位**：先查后写在同一调用内完成，避免同批两帧都放行；
/// - 撤销按 identity 反查（`approval/resolved` 帧不带 sessionId，只有 approvalId/rpcId）；
/// - `markDismissed` 只改状态，不删除记录——否则"点取消后又因为重放弹回来"。
class AttentionLedger {
  AttentionLedger({this.capacity = 128});

  final int capacity;
  final Map<String, AttentionEntry> _byKey = {};
  final Map<int, String> _keyById = {};

  Iterable<AttentionEntry> get entries => _byKey.values;

  AttentionEntry? byKey(String key) => _byKey[key];

  AttentionEntry? byId(int id) {
    final key = _keyById[id];
    return key == null ? null : _byKey[key];
  }

  /// 是否在 [window] 内提醒过（只读，不改状态）。
  bool seenRecently(String key, {required DateTime now, Duration window = const Duration(minutes: 5)}) {
    final entry = _byKey[key];
    if (entry == null) return false;
    if (entry.status == AttentionStatus.resolved) return false;
    return now.difference(entry.at) < window;
  }

  /// 原子占位：未提醒过则登记并返回 true。
  bool reserve(AttentionEvent event, {Duration window = const Duration(minutes: 5)}) {
    if (seenRecently(event.key, now: event.at, window: window)) return false;
    _put(AttentionEntry(
      key: event.key,
      id: event.notificationId,
      kind: event.kind,
      sessionId: event.sessionId,
      at: event.at,
    ));
    return true;
  }

  /// 更新状态（blocked / dismissed / resolved）。
  void mark(String key, AttentionStatus status) {
    final entry = _byKey[key];
    if (entry == null) return;
    entry.status = status;
  }

  /// 按身份撤销：resolved 帧只带 approvalId / questionRpcId。
  ///
  /// 返回被撤销的 id（用于 `cancel(id)`）；找不到说明从未提醒过，返回 null。
  int? resolveByIdentity(String identity) {
    for (final entry in _byKey.values) {
      if (entry.key.endsWith('|$identity') &&
          entry.status != AttentionStatus.resolved) {
        entry.status = AttentionStatus.resolved;
        return entry.id;
      }
    }
    return null;
  }

  /// 移除记录（对账时用：系统里已经没有这条通知了）。
  void forget(String key) {
    final entry = _byKey.remove(key);
    if (entry != null) _keyById.remove(entry.id);
  }

  /// 当前仍未处理的条目（用于"回前台补提示"或角标）。
  List<AttentionEntry> get activeEntries => _byKey.values
      .where((e) => e.status == AttentionStatus.active)
      .toList(growable: false);

  List<Map<String, dynamic>> toJson() =>
      _byKey.values.map((e) => e.toJson()).toList(growable: false);

  void restore(List<Map<String, dynamic>> rows) {
    _byKey.clear();
    _keyById.clear();
    for (final row in rows) {
      final entry = AttentionEntry.fromJson(row);
      if (entry != null) _put(entry);
    }
  }

  void _put(AttentionEntry entry) {
    _byKey[entry.key] = entry;
    _keyById[entry.id] = entry.key;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    if (_byKey.length <= capacity) return;
    // 先淘汰最旧的已结算条目，避免把仍在等待的提醒挤掉。
    final sorted = _byKey.values.toList()
      ..sort((a, b) {
        final ra = a.status == AttentionStatus.resolved ? 0 : 1;
        final rb = b.status == AttentionStatus.resolved ? 0 : 1;
        if (ra != rb) return ra.compareTo(rb);
        return a.at.compareTo(b.at);
      });
    for (final entry in sorted.take(_byKey.length - capacity)) {
      _keyById.remove(entry.id);
      _byKey.remove(entry.key);
    }
  }

  /// 调试/日志用：保留的最小与最大 id。
  (int, int) get idRange {
    if (_keyById.isEmpty) return (0, 0);
    final ids = _keyById.keys.toList()..sort();
    return (ids.first, ids.last);
  }

  /// 供测试断言：id 必须落在业务号段内，且不等于保留值。
  static bool isValidNotificationId(int id) =>
      id >= attentionIdBase && id < attentionIdBase + attentionIdSpan;

  /// 测试辅助：给出与 [reserved] 的距离（用于断言不自碰撞）。
  static int distanceToReserved(int id, int reserved) => (id - reserved).abs();

  /// 未被使用的占位（避免 analyzer 报 unused 的 math 导入）。
  static int clampNonNegative(int v) => math.max(0, v);
}
