// issue #46：连接状态下的本地通知（pushUrls 仅作离线兜底）。
//
// 设计边界：
// - 只在 Android 上启用（当前 App 只有 Android 端）；
// - 只在 App **不在前台**时弹系统通知——前台已有 App 内审批卡与顶部横幅，再弹系统通知是重复打扰；
// - 通知点击携带 sessionId，交由 main.dart 走统一的 openChat 入口；
// - 同一 rpcId 在窗口期内只提醒一次（SSE 重连/回放会重复投递未结算帧）。
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _channelId = 'dsh_attention';
const _channelName = '需要你处理';

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
  bool _ready = false;
  bool _foreground = true;

  /// 点击通知时回调（携带 sessionId），由 main.dart 接到 openChat。
  void Function(String sessionId)? onOpenSession;

  bool get ready => _ready;

  set foreground(bool value) => _foreground = value;

  Future<void> init() async {
    if (!Platform.isAndroid || _ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final sessionId = response.payload;
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
      // Android 13+ 需要运行时权限；用户拒绝时保持 ready=false，静默退化为 App 内提醒。
      final granted = await android?.requestNotificationsPermission();
      _ready = granted ?? true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<void> showAttention({
    required String kind,
    required String rpcId,
    required String sessionId,
    String? toolName,
    String? reason,
    String? prompt,
    String? sessionTitle,
  }) async {
    if (!_ready || _foreground) return;
    if (!_dedupe.shouldNotify('$kind:$rpcId')) return;
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
        id: sessionId.hashCode & 0x7fffffff,
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
        payload: sessionId,
      );
    } catch (_) {
      // 系统层拒绝/通道被删时不阻断主流程
    }
  }

  /// 回到前台时清掉已过时的提醒（卡片已在 App 内呈现）。
  Future<void> clearAll() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }
}
