// issue #46：连接状态下的本地通知（pushUrls 仅作离线兜底）。
//
// 设计边界：
// - 只在 Android 上启用（当前 App 只有 Android 端）；
// - **只在「正看着这条提醒所属的会话」时才不弹系统通知**——此时 App 内已有审批卡/横幅，
//   再弹系统通知是重复打扰；停在会话列表、设置页等其它页面照常弹（v3.3.1 调整：
//   原来是"App 在前台就一律不弹"，真机上表现为"审批挂了十几秒也没通知"）；
// - 通知点击携带 sessionId，交由 main.dart 走统一的 openChat 入口；
// - 同一 rpcId 在窗口期内只提醒一次（SSE 重连/回放会重复投递未结算帧）。
//
// v3.3.1（可观测性）：真机反馈「审批通知有时不弹，挂到超时也不弹」。此前每个提前返回的分支都是
// 静默的（未就绪 / 前台 / 去重 / 系统拒绝），现场没有任何线索。现在**每个分支都写一行日志**，
// 并把权限查询（areNotificationsEnabled）拆出来，用户手动开启后不必重启 App。
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'dart:convert';

import 'logger.dart';
import 'attention.dart';

const _channelId = 'dsh_attention';
const _channelName = '需要你处理';

/// 一次展示的结果。`show()` 不抛异常不代表用户能看到（权限/渠道静音都可能吞掉）。
enum AttentionShowResult { shown, blocked, failed }

/// 生成通知标题与正文（纯函数，便于单测）。
({String title, String body}) attentionCopy({
  required String kind,
  required String sessionId,
  String? toolName,
  String? reason,
  String? prompt,
  String? sessionTitle,
}) {
  final who = (sessionTitle != null && sessionTitle.trim().isNotEmpty)
      ? sessionTitle.trim()
      : sessionId;
  if (kind == 'approval') {
    final name = (toolName != null && toolName.trim().isNotEmpty)
        ? toolName.trim()
        : '工具调用';
    final detail = (reason != null && reason.trim().isNotEmpty)
        ? reason.trim()
        : '等待你授权';
    return (title: '需要授权：$name', body: '$detail\n$who');
  }
  final text = (prompt != null && prompt.trim().isNotEmpty)
      ? prompt.trim()
      : 'agent 在等你回答';
  return (title: '需要你回答', body: '$text\n$who');
}

/// 去重：同一 key 在 [window] 内只放行一次。
class AttentionDeduper {
  AttentionDeduper({
    this.window = const Duration(minutes: 5),
    this.maxEntries = 64,
  });

  final Duration window;
  final int maxEntries;
  final Map<String, DateTime> _seen = {};

  bool shouldNotify(String key, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final last = _seen[key];
    if (last != null && at.difference(last) < window) return false;
    _seen[key] = at;
    if (_seen.length > maxEntries) {
      final entries = _seen.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final entry in entries.take(_seen.length - maxEntries)) {
        _seen.remove(entry.key);
      }
    }
    return true;
  }
}

/// 进程内单例：初始化一次，之后只负责 show / 点击回传。
class LocalNotifier {
  LocalNotifier._();

  static final LocalNotifier instance = LocalNotifier._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final AttentionDeduper _dedupe = AttentionDeduper();
  AndroidFlutterLocalNotificationsPlugin? _android;
  bool _ready = false;
  bool _foreground = true;

  /// 当前正被用户看着的会话（聊天页在栈顶时由 ChatScreen 设置）。
  ///
  /// 只有「前台 + 正看着这条提醒所属的会话」才静音；停在列表等其它页面时照常弹系统通知。
  String? visibleSession;

  /// 点击通知时回调（携带 sessionId），由 main.dart 接到 openChat。
  void Function(String sessionId)? onOpenSession;

  /// 冷启动时由通知点开的会话（此时 main.dart 还没挂上 onOpenSession）。
  String? _pendingOpenSession;

  /// 取出并清空冷启动遗留的会话 id（main.dart 挂好回调后调用）。
  String? consumePendingOpenSession() {
    final s = _pendingOpenSession;
    _pendingOpenSession = null;
    return s;
  }

  /// 解析通知 payload：现行格式是 JSON `{'s':sessionId,'k':kind,'key':…,'id':…}`，
  /// 旧格式是裸 sessionId。**直接拿 payload 当 sessionId 会导致点了打不开会话**
  /// ——payload 变成 JSON 之后这里忘了跟着改过（2026-10-31 复盘发现）。
  String? sessionIdFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    if (payload.startsWith('{')) {
      try {
        final m = jsonDecode(payload);
        if (m is Map) {
          final s = m['s'];
          if (s is String && s.trim().isNotEmpty) return s.trim();
          // 合法 JSON 但没有会话：明确返回 null，别把整段 JSON 当 id 传下去。
          return null;
        }
      } catch (_) {
        // 不是合法 JSON：按裸 id 处理
      }
    }
    return payload;
  }

  bool get ready => _ready;

  set foreground(bool value) => _foreground = value;

  Future<void> init() async {
    if (!Platform.isAndroid) {
      AppLog.instance.log('通知：非 Android 平台，跳过本地通知');
      return;
    }
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final sessionId = sessionIdFromPayload(response.payload);
          AppLog.instance.log(
            '通知：点击（session=${sessionId ?? "空"}）→ 打开会话',
          );
          if (sessionId != null && sessionId.isNotEmpty) {
            onOpenSession?.call(sessionId);
          }
        },
      );
      final android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: '审批与提问提醒（App 在线时）',
          importance: Importance.high,
        ),
      );
      _android = android;
      // Android 13+ 需要运行时权限；用户拒绝时保持 ready=false，静默退化为 App 内提醒，
      // 但**必须留日志**——否则现场只能看到"没弹"，不知道是没权限还是别的原因。
      _ready = await ensurePermission();
      AppLog.instance.log('通知：初始化完成（ready=$_ready）');
      // 冷启动由通知点开：此时 main.dart 还没挂 onOpenSession，先暂存，等它来取。
      try {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp == true) {
          final sid = sessionIdFromPayload(
            launch?.notificationResponse?.payload,
          );
          if (sid != null && sid.isNotEmpty) {
            _pendingOpenSession = sid;
            AppLog.instance.log('通知：冷启动由通知打开 → 暂存 session=$sid');
          }
        }
      } catch (e) {
        AppLog.instance.log('通知：读取冷启动来源失败（$e）');
      }
    } catch (e) {
      _ready = false;
      AppLog.instance.log('通知：初始化失败（$e）');
    }
  }

  /// 查询并（必要时）请求通知权限；返回当前是否允许发通知。
  ///
  /// 关键点：`requestNotificationsPermission()` 只在第一次有效，之后系统不再弹窗。
  /// 所以每次先查 `areNotificationsEnabled()`——用户在系统设置里手动开启后，无需重启 App。
  Future<bool> ensurePermission() async {
    final android = _android;
    if (android == null) return _ready;
    try {
      var enabled = await android.areNotificationsEnabled() ?? false;
      if (!enabled) {
        enabled = await android.requestNotificationsPermission() ?? false;
      }
      AppLog.instance.log('通知：权限检查 → $enabled');
      return enabled;
    } catch (e) {
      AppLog.instance.log('通知：权限检查失败（$e）');
      return false;
    }
  }

  /// 展示结果：调用方据此回写 ledger（`show()` 不抛 ≠ 用户能看到）。
  Future<AttentionShowResult> showAttentionEvent({
    required int id,
    required String key,
    required String kind,
    required String sessionId,
    String? toolName,
    String? reason,
    String? prompt,
    String? sessionTitle,
  }) async {
    AppLog.instance.log(
      '通知：请求展示 kind=$kind key=$key id=$id session=$sessionId '
      'ready=$_ready foreground=$_foreground visible=$visibleSession',
    );
    if (!_ready) {
      // 权限可能在系统设置里被改过：再查一次，避免"必须重启 App 才生效"。
      _ready = await ensurePermission();
      if (!_ready) {
        AppLog.instance.log('通知：跳过——未获得通知权限（ready=false）');
        return AttentionShowResult.blocked;
      }
    }
    final copy = attentionCopy(
      kind: kind,
      sessionId: sessionId,
      toolName: toolName,
      reason: reason,
      prompt: prompt,
      sessionTitle: sessionTitle,
    );
    try {
      await _plugin.show(
        id: id,
        title: copy.title,
        body: copy.body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: '审批与提问提醒（App 在线时）',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
          ),
        ),
        payload: jsonEncode({'s': sessionId, 'k': kind, 'key': key, 'id': id}),
      );
      AppLog.instance.log('通知：已展示 id=$id（$kind key=$key）');
      return AttentionShowResult.shown;
    } catch (e) {
      // 系统层拒绝/通道被删时不阻断主流程，但要留痕。
      AppLog.instance.log('通知：展示失败（$e）');
      return AttentionShowResult.failed;
    }
  }

  /// 撤销一条系统通知（按 id 精确撤，**不要**用 cancelAll）。
  Future<void> cancel(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: id);
      AppLog.instance.log('通知：已撤销 id=$id');
    } catch (e) {
      AppLog.instance.log('通知：撤销失败 id=$id（$e）');
    }
  }

  /// 旧入口（保留兼容）：内部改用固定 key，仍按 sessionId 派生 id。
  ///
  /// 新代码请用 [showAttentionEvent]，它接受 ledger 派生的稳定 id。
  Future<void> showAttention({
    required String kind,
    required String rpcId,
    required String sessionId,
    String? toolName,
    String? reason,
    String? prompt,
    String? sessionTitle,
  }) async {
    if (!_ready) {
      _ready = await ensurePermission();
      if (!_ready) return;
    }
    if (_foreground && visibleSession == sessionId) {
      AppLog.instance.log('通知：跳过——正在看该会话（前台只走应用内卡片/横幅）');
      return;
    }
    if (!_dedupe.shouldNotify('$kind:$rpcId')) {
      AppLog.instance.log('通知：跳过——去重命中（$kind:$rpcId 已在窗口期内提醒过）');
      return;
    }
    await showAttentionEvent(
      id: stableNotificationId(attentionKey(
        kind: kind,
        sessionId: sessionId,
        identity: rpcId,
      )),
      key: attentionKey(kind: kind, sessionId: sessionId, identity: rpcId),
      kind: kind,
      sessionId: sessionId,
      toolName: toolName,
      reason: reason,
      prompt: prompt,
      sessionTitle: sessionTitle,
    );
  }

  /// 回到前台时清掉已过时的提醒（卡片已在 App 内呈现）。
  Future<void> clearAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }
}
